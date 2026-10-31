USE ROLE ACCOUNTADMIN;

CREATE WAREHOUSE IF NOT EXISTS CATALOG_WH 
WITH WAREHOUSE_SIZE = 'XSMALL' 
AUTO_SUSPEND = 60 
AUTO_RESUME = TRUE;

CREATE DATABASE IF NOT EXISTS CATALOG_DB;
CREATE SCHEMA IF NOT EXISTS CATALOG_DB.RAW;
CREATE SCHEMA IF NOT EXISTS CATALOG_DB.SILVER;
CREATE SCHEMA IF NOT EXISTS CATALOG_DB.GOLD;

USE SCHEMA CATALOG_DB.RAW;

CREATE OR REPLACE FILE FORMAT CSV_FORMAT
    TYPE = 'CSV' 
    FIELD_DELIMITER = ',' 
    SKIP_HEADER = 1 
    FIELD_OPTIONALLY_ENCLOSED_BY = '"' 
    TRIM_SPACE = TRUE 
    NULL_IF = ('', 'NULL', 'null');

CREATE OR REPLACE STAGE INTERNAL_CATALOG_STAGE 
FILE_FORMAT = CSV_FORMAT;

show stages in schema catalog_DB.raw;

list @INTERNAL_CATALOG_STAGE;

CREATE OR REPLACE TABLE RAW.STYLEHAUS_PRODUCTS (
    sku VARCHAR(100), product_name VARCHAR(500), brand VARCHAR(200), category VARCHAR(200),
    description TEXT, price NUMBER(10, 2), color VARCHAR(100), size VARCHAR(50),
    material VARCHAR(200), in_stock BOOLEAN, updated_at TIMESTAMP_NTZ
);

CREATE OR REPLACE TABLE RAW.URBANTHREAD_PRODUCTS (
    product_code VARCHAR(100), title VARCHAR(500), manufacturer VARCHAR(200), type VARCHAR(200),
    details TEXT, retail_price NUMBER(10, 2), colour VARCHAR(100), dimensions VARCHAR(50),
    fabric VARCHAR(200), availability VARCHAR(100), last_modified TIMESTAMP_NTZ
);

COPY INTO RAW.STYLEHAUS_PRODUCTS 
FROM @INTERNAL_CATALOG_STAGE/stylehaus_products.csv 
FILE_FORMAT = CSV_FORMAT 
ON_ERROR = 'CONTINUE';

COPY INTO RAW.URBANTHREAD_PRODUCTS 
FROM @INTERNAL_CATALOG_STAGE/urbanthread_products.csv 
FILE_FORMAT = CSV_FORMAT 
ON_ERROR = 'CONTINUE';

select * from STYLEHAUS_PRODUCTS;

select * from URBANTHREAD_PRODUCTS;

SHOW TABLES IN SCHEMA CATALOG_DB.SILVER;

USE SCHEMA CATALOG_DB.SILVER;

show views;
show tables;

select * from CATALOG_PRODCUTS_NORMALIZED;

-- 768-d VECTOR EMBEDDINGS --
CREATE OR REPLACE TABLE SILVER.PRODUCT_EMBEDDINGS AS 
SELECT 
    catalog_record_key,
    source_system_name,
    source_product_id,
    product_name,
    normalized_product_name,
    brand_name,
    product_category,
    product_description,
    product_price,
    product_color,
    size_value,
    material_description,
    is_in_stock,
    source_last_modified_at,
    composite_text,
    AI_EMBED('snowflake-arctic-embed-m', composite_text) AS text_embedding
FROM SILVER.CATALOG_PRODCUTS_NORMALIZED;

select * from PRODUCT_EMBEDDINGS;

-- Quick Sanity Check: Rows Reconcilation --
SELECT 
    source_system_name,
    COUNT(*) AS embedded_rows 
FROM SILVER.PRODUCT_EMBEDDINGS
GROUP BY source_system_name;

-- Check total rows and missing embeddings --
SELECT
    COUNT(*) AS total_rows,
    COUNT_IF(text_embedding IS NULL) AS missing_embeddings
FROM SILVER.PRODUCT_EMBEDDINGS;

--  Block Candidate Pairs and Create cross-retailer product match candidates and Compute Vector Cosine Similarity --
CREATE OR REPLACE TABLE SILVER.PRODUCT_MATCH_CANDIDATES AS
WITH blocked_pairs AS (
    SELECT
        a.catalog_record_key AS rec_a_key,
        a.source_system_name AS rec_a_source,
        a.source_product_id AS rec_a_product_id,
        a.product_name AS rec_a_product_name,
        a.brand_name AS rec_a_brand,
        a.product_category AS rec_a_category,
        a.product_color AS rec_a_color,
        a.size_value AS rec_a_size,
        a.material_description AS rec_a_material,
        a.product_price AS rec_a_price,
        a.product_description AS rec_a_description,
        a.source_last_modified_at AS rec_a_updated_at,

        b.catalog_record_key AS rec_b_key,
        b.source_system_name AS rec_b_source,
        b.source_product_id AS rec_b_product_id,
        b.product_name AS rec_b_product_name,
        b.brand_name AS rec_b_brand,
        b.product_category AS rec_b_category,
        b.product_color AS rec_b_color,
        b.size_value AS rec_b_size,
        b.material_description AS rec_b_material,
        b.product_price AS rec_b_price,
        b.product_description AS rec_b_description,
        b.source_last_modified_at AS rec_b_updated_at,

        VECTOR_COSINE_SIMILARITY( a.text_embedding, b.text_embedding ) AS similarity_score
    FROM SILVER.PRODUCT_EMBEDDINGS a

    INNER JOIN SILVER.PRODUCT_EMBEDDINGS b
        ON (a.brand_name = b.brand_name OR a.product_category = b.product_category)
        AND a.source_system_name < b.source_system_name

    WHERE a.text_embedding IS NOT NULL
      AND b.text_embedding IS NOT NULL
      AND a.catalog_record_key <> b.catalog_record_key
),

scored_pairs AS (
    SELECT *,
        CASE
            WHEN similarity_score >= 0.88
                THEN 'AUTO_MATCH'
            WHEN similarity_score >= 0.72
                THEN 'AI_COMPLETE_VERIFY'
            ELSE 'NON_MATCH'
        END AS match_decision_tier
    FROM blocked_pairs
)

SELECT *
FROM scored_pairs
WHERE similarity_score >= 0.72;

SELECT * from PRODUCT_MATCH_CANDIDATES;

-- Inspect how many pairs fell into AUTO_MATCH vs ARGON_VERIFY (Gray Zone) --
SELECT
    match_decision_tier,
    COUNT(*) AS candidate_pair_count,
    ROUND(MIN(similarity_score), 3) AS min_similarity,    
    ROUND(MAX(similarity_score), 3) AS max_similarity
FROM SILVER.PRODUCT_MATCH_CANDIDATES
GROUP BY match_decision_tier;

-- evaluating gray-zone candidates  --

CREATE OR REPLACE TABLE SILVER.AI_REVIEW_RESULTS AS
WITH gray_zone_candidates AS (
    SELECT *
    FROM SILVER.PRODUCT_MATCH_CANDIDATES
    WHERE similarity_score >= 0.72
      AND similarity_score < 0.88
),

ai_inference AS (
    SELECT
        rec_a_key,
        rec_a_source,
        rec_a_product_id,
        rec_a_product_name,
        rec_a_brand,
        rec_a_category,
        rec_a_color,
        rec_a_size,
        rec_a_material,
        rec_a_price,
        rec_a_description,

        rec_b_key,
        rec_b_source,
        rec_b_product_id,
        rec_b_product_name,
        rec_b_brand,
        rec_b_category,
        rec_b_color,
        rec_b_size,
        rec_b_material,
        rec_b_price,
        rec_b_description,
        similarity_score,
        AI_COMPLETE(
            model => 'gemini-3.5-flash',
            prompt => CONCAT(
                'You are an E-Commerce Product matching (MDM) auditor. ',
                'Evaluate whether Product A and Product B are the ',
                'exact same physical retail product, including model, ',
                'color and size. Similar descriptions alone are not enough.',

                '\n\nPRODUCT A',
                '\nSource: ', COALESCE(rec_a_source, 'Unknown'),
                '\nProduct ID: ', COALESCE(rec_a_product_id, 'Unknown'),
                '\nName: ', COALESCE(rec_a_product_name, 'Unknown'),
                '\nBrand: ', COALESCE(rec_a_brand, 'Unknown'),
                '\nCategory: ', COALESCE(rec_a_category, 'Unknown'),
                '\nColor: ', COALESCE(rec_a_color, 'Unknown'),
                '\nSize: ', COALESCE(rec_a_size, 'Unknown'),
                '\nMaterial: ', COALESCE(rec_a_material, 'Unknown'),
                '\nPrice: ', COALESCE(TO_VARCHAR(rec_a_price), 'Unknown'),
                '\nDescription: ', COALESCE(rec_a_description, 'Unknown'),

                '\n\nPRODUCT B',
                '\nSource: ', COALESCE(rec_b_source, 'Unknown'),
                '\nProduct ID: ', COALESCE(rec_b_product_id, 'Unknown'),
                '\nName: ', COALESCE(rec_b_product_name, 'Unknown'),
                '\nBrand: ', COALESCE(rec_b_brand, 'Unknown'),
                '\nCategory: ', COALESCE(rec_b_category, 'Unknown'),
                '\nColor: ', COALESCE(rec_b_color, 'Unknown'),
                '\nSize: ', COALESCE(rec_b_size, 'Unknown'),
                '\nMaterial: ', COALESCE(rec_b_material, 'Unknown'),
                '\nPrice: ', COALESCE(TO_VARCHAR(rec_b_price), 'Unknown'),
                '\nDescription: ', COALESCE(rec_b_description, 'Unknown'),

                '\n\nRULES:',
                '\n1. Different sizes or colorways mean NOT_DUPLICATE.',
                '\n2. Different brands normally mean NOT_DUPLICATE, ',
                'unless the evidence clearly establishes a data-labeling issue.',
                '\n3. Missing attributes are unknown; do not assume they match.',
                '\n4. Different prices do not automatically mean different products.',
                '\n5. If evidence is insufficient, return NEEDS_MANUAL_REVIEW.',
                '\n6. Return only a decision supported by the supplied records.'
            ),

            model_parameters => {
                'temperature': 0,
                'max_tokens': 300
            },

            response_format => TYPE OBJECT(
                decision STRING,
                confidence FLOAT,
                reason STRING
            )
        ) AS ai_decision

    FROM gray_zone_candidates
)

SELECT
    rec_a_key,
    rec_a_source,
    rec_a_product_id,
    rec_a_product_name,
    rec_a_brand,
    rec_a_category,
    rec_a_color,
    rec_a_size,
    rec_a_material,
    rec_a_price,

    rec_b_key,
    rec_b_source,
    rec_b_product_id,
    rec_b_product_name,
    rec_b_brand,
    rec_b_category,
    rec_b_color,
    rec_b_size,
    rec_b_material,
    rec_b_price,

    similarity_score,

    UPPER(ai_decision:decision::VARCHAR) AS ai_match_decision,

    ai_decision:confidence::FLOAT AS ai_confidence,

    ai_decision:reason::VARCHAR AS resolution_reason,

    'AI_COMPLETE' AS resolution_method,
    'gemini-3.5-flash' AS model_name,
    CURRENT_TIMESTAMP() AS reviewed_at

FROM ai_inference;

select * from AI_REVIEW_RESULTS;

-- Resolve 1:1 Matches & Assign Unified Cluster IDs (Support 2,3, or N Overlapping Products) --
CREATE OR REPLACE TABLE SILVER.RESOLVED_ENTITY_CLUSTERS AS
WITH verified_edges AS (
    SELECT rec_a_key, rec_b_key, similarity_score, 'AUTO_EMBEDDING' AS resolution_method, 1.0::FLOAT AS ai_confidence
    FROM CATALOG_DB.SILVER.PRODUCT_MATCH_CANDIDATES
    WHERE match_decision_tier = 'AUTO_MATCH'
    
    UNION ALL
    
    SELECT rec_a_key, rec_b_key, similarity_score, resolution_method, ai_confidence
    FROM SILVER.AI_REVIEW_RESULTS
),
-- Enforce strict 1:1 best match per SKU so one product never merges with two distinct products
deduped_edges AS (
    SELECT 
        rec_a_key,
        rec_b_key,
        similarity_score,
        resolution_method,
        ai_confidence,
        ROW_NUMBER() OVER (PARTITION BY rec_a_key ORDER BY similarity_score DESC, ai_confidence DESC) AS rn_a,
        ROW_NUMBER() OVER (PARTITION BY rec_b_key ORDER BY similarity_score DESC, ai_confidence DESC) AS rn_b
    FROM verified_edges
    QUALIFY rn_a = 1 AND rn_b = 1
),
-- Undirected edge list for transitive clustering across >2 brands (A<->B, B<->C => shared anchor ID)
undirected_edges AS (
    SELECT rec_a_key AS node_id, rec_b_key AS neighbor_id, similarity_score, resolution_method, ai_confidence FROM deduped_edges
    UNION ALL
    SELECT rec_b_key AS node_id, rec_a_key AS neighbor_id, similarity_score, resolution_method, ai_confidence FROM deduped_edges
),
hop_1 AS (
    SELECT 
        p.catalog_record_key AS node_id,
        LEAST(p.catalog_record_key, COALESCE(MIN(e.neighbor_id), p.catalog_record_key)) AS anchor_1,
        MAX(e.similarity_score) AS max_similarity,
        MAX(e.resolution_method) AS primary_method,
        MAX(e.ai_confidence) AS avg_confidence
    FROM CATALOG_PRODCUTS_NORMALIZED p
    LEFT JOIN undirected_edges e ON p.catalog_record_key = e.node_id
    GROUP BY p.catalog_record_key
),
hop_2 AS (
    SELECT 
        h1.node_id,
        LEAST(h1.anchor_1, COALESCE(MIN(h2_neighbor.anchor_1), h1.anchor_1)) AS cluster_anchor_id,
        h1.max_similarity,
        h1.primary_method,
        h1.avg_confidence
    FROM hop_1 h1
    LEFT JOIN undirected_edges e ON h1.node_id = e.node_id
    LEFT JOIN hop_1 h2_neighbor ON e.neighbor_id = h2_neighbor.node_id
    GROUP BY h1.node_id, h1.anchor_1, h1.max_similarity, h1.primary_method, h1.avg_confidence
)
SELECT 
    'GOLD-' || SUBSTR(MD5(cluster_anchor_id), 1, 12) AS cluster_product_id,
    node_id AS catalog_record_key,
    max_similarity AS similarity_score,
    COALESCE(primary_method, 'SINGLETON') AS resolution_method,
    COALESCE(avg_confidence, 1.0) AS confidence,
    CURRENT_TIMESTAMP() AS resolved_at
FROM hop_2;

select * from RESOLVED_ENTITY_CLUSTERS;

-- Verification Check: See how many products merged vs stayed unique
SELECT 
    resolution_method,
    COUNT(DISTINCT cluster_product_id) AS unique_gold_products,
    COUNT(*) AS total_source_records
FROM SILVER.RESOLVED_ENTITY_CLUSTERS
GROUP BY resolution_method;

USE SCHEMA CATALOG_DB.GOLD;

-- Create Unified Catalog Table (Gold) --
CREATE OR REPLACE TABLE GOLD.UNIFIED_PRODUCT_CATALOG (
    product_id                  VARCHAR(100) NOT NULL PRIMARY KEY,
    product_name                VARCHAR(500) NOT NULL,
    brand                       VARCHAR(200) NOT NULL,
    category                    VARCHAR(200) NOT NULL,
    description                 TEXT,
    price                       NUMBER(10, 2) NOT NULL,
    color                       VARCHAR(100),
    size                        VARCHAR(50),
    material                    VARCHAR(200),
    in_stock                    BOOLEAN NOT NULL,
    effective_updated_at        TIMESTAMP_NTZ NOT NULL,
    is_merged                   BOOLEAN NOT NULL,
    merged_product_count        INTEGER NOT NULL,
    contributing_brands         ARRAY NOT NULL,
    source_identifiers          ARRAY NOT NULL,
    match_metadata              VARIANT,
    lineage_metadata            VARIANT NOT NULL COMMENT 'Field-level provenance map indicating which source system contributed each column',
    created_at                  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Populate Gold Catalog using Windowed Survivorship Rules --
INSERT INTO GOLD.UNIFIED_PRODUCT_CATALOG (
    product_id,
    product_name,
    brand,
    category,
    description,
    price,
    color,
    size,
    material,
    in_stock,
    effective_updated_at,
    is_merged,
    merged_product_count,
    contributing_brands,
    source_identifiers,
    match_metadata,
    lineage_metadata
)
WITH cluster_members AS (
    SELECT 
        c.cluster_product_id,
        c.similarity_score,
        c.resolution_method,
        c.resolved_at,
        p.*
    FROM SILVER.RESOLVED_ENTITY_CLUSTERS c
    INNER JOIN SILVER.CATALOG_PRODCUTS_NORMALIZED p
        ON c.catalog_record_key = p.catalog_record_key
),
windowed_survivorship AS (
    SELECT 
        cluster_product_id AS product_id,
        
        -- Business Rule 1A: Prefer longer, more descriptive product_name (tie-break by most recent)
        FIRST_VALUE(product_name) OVER (
            PARTITION BY cluster_product_id 
            ORDER BY LENGTH(product_name) DESC, source_last_modified_at DESC
        ) AS winning_product_name,
        FIRST_VALUE(source_system_name) OVER (
            PARTITION BY cluster_product_id 
            ORDER BY LENGTH(product_name) DESC, source_last_modified_at DESC
        ) AS lineage_product_name,

        -- Business Rule 1B: Prefer longer, more descriptive description (tie-break by most recent)
        FIRST_VALUE(product_description) OVER (
            PARTITION BY cluster_product_id 
            ORDER BY LENGTH(COALESCE(product_description, '')) DESC, source_last_modified_at DESC
        ) AS winning_description,
        FIRST_VALUE(source_system_name) OVER (
            PARTITION BY cluster_product_id 
            ORDER BY LENGTH(COALESCE(product_description, '')) DESC, source_last_modified_at DESC
        ) AS lineage_description,

        -- Business Rule 2: Use the lower price (tie-break by most recent)
        FIRST_VALUE(product_price) OVER (
            PARTITION BY cluster_product_id 
            ORDER BY product_price ASC, source_last_modified_at DESC
        ) AS winning_price,
        FIRST_VALUE(source_system_name) OVER (
            PARTITION BY cluster_product_id 
            ORDER BY product_price ASC, source_last_modified_at DESC
        ) AS lineage_price,

        -- Business Rule 3: Use the most recently updated value for all other fields
        FIRST_VALUE(brand_name)      OVER (PARTITION BY cluster_product_id ORDER BY source_last_modified_at DESC) AS winning_brand,
        FIRST_VALUE(product_category) OVER (PARTITION BY cluster_product_id ORDER BY source_last_modified_at DESC) AS winning_category,
        FIRST_VALUE(product_color)   OVER (PARTITION BY cluster_product_id ORDER BY source_last_modified_at DESC) AS winning_color,
        FIRST_VALUE(size_value)      OVER (PARTITION BY cluster_product_id ORDER BY source_last_modified_at DESC) AS winning_size,
        FIRST_VALUE(material_description) OVER (PARTITION BY cluster_product_id ORDER BY source_last_modified_at DESC) AS winning_material,
        FIRST_VALUE(is_in_stock)     OVER (PARTITION BY cluster_product_id ORDER BY source_last_modified_at DESC) AS winning_in_stock,
        FIRST_VALUE(source_system_name) OVER (PARTITION BY cluster_product_id ORDER BY source_last_modified_at DESC) AS lineage_latest_source,

        -- Deduplicate window to 1 row per cluster_product_id
        ROW_NUMBER() OVER (PARTITION BY cluster_product_id ORDER BY source_last_modified_at DESC) AS cluster_rn
    FROM cluster_members
),
cluster_aggregates AS (
    SELECT 
        cluster_product_id,
        COUNT(*) AS merged_product_count,
        MAX(source_last_modified_at) AS effective_updated_at,
        ARRAY_AGG(DISTINCT source_system_name) WITHIN GROUP (ORDER BY source_system_name) AS contributing_brands,
        ARRAY_AGG(OBJECT_CONSTRUCT('source_system', source_system_name, 'product_id', source_product_id)) WITHIN GROUP (ORDER BY source_system_name) AS source_identifiers,
        MAX(similarity_score) AS similarity_score,
        MAX(resolution_method) AS resolution_method,
        MAX(resolved_at) AS resolved_at
    FROM cluster_members
    GROUP BY cluster_product_id
)
SELECT 
    w.product_id,
    w.winning_product_name AS product_name,
    w.winning_brand        AS brand,
    w.winning_category     AS category,
    w.winning_description  AS description,
    w.winning_price        AS price,
    w.winning_color        AS color,
    w.winning_size         AS size,
    w.winning_material     AS material,
    w.winning_in_stock     AS in_stock,
    a.effective_updated_at,
    IFF(a.merged_product_count > 1, TRUE, FALSE) AS is_merged,
    a.merged_product_count,
    a.contributing_brands,
    a.source_identifiers,
    IFF(
        a.merged_product_count > 1,
        OBJECT_CONSTRUCT(
            'similarity_score', a.similarity_score,
            'resolution_method', a.resolution_method,
            'resolved_at', a.resolved_at
        ),
        NULL
    ) AS match_metadata,
    -- Business Rule 4: Field-level lineage tracking which source system supplied each column
    OBJECT_CONSTRUCT(
        'product_name', w.lineage_product_name,
        'description',  w.lineage_description,
        'price',        w.lineage_price,
        'brand',        w.lineage_latest_source,
        'category',     w.lineage_latest_source,
        'color',        w.lineage_latest_source,
        'size',         w.lineage_latest_source,
        'material',     w.lineage_latest_source,
        'in_stock',     w.lineage_latest_source
    ) AS lineage_metadata
FROM windowed_survivorship w
INNER JOIN cluster_aggregates a
    ON w.product_id = a.cluster_product_id
WHERE w.cluster_rn = 1;

select * from GOLD.UNIFIED_PRODUCT_CATALOG;


-- Summary Check: Expect ~36 merged rows (is_merged = TRUE) and ~92 unique rows (is_merged = FALSE) = ~164 total rows --
SELECT 
    is_merged,
    merged_product_count,
    COUNT(*) AS gold_product_rows,
    ROUND(AVG(price), 2) AS avg_winning_price
FROM CATALOG_DB.GOLD.UNIFIED_PRODUCT_CATALOG
GROUP BY is_merged, merged_product_count
ORDER BY is_merged DESC;

-- 2. Inspect 5 Merged Golden Records and their Column-Level Lineage JSON
SELECT 
    product_id,
    product_name,
    price,
    contributing_brands,
    source_identifiers,
    match_metadata,
    lineage_metadata
FROM CATALOG_DB.GOLD.UNIFIED_PRODUCT_CATALOG
WHERE is_merged = TRUE
LIMIT 5;

-- 1. ENDPOINT 1: GET /products/search?q={query}&limit={limit}
-- Returns ranked top products with relevance_score as a JSON payload


CREATE OR REPLACE FUNCTION CATALOG_DB.GOLD.API_SEARCH_PRODUCTS(
    search_query VARCHAR,
    max_results INT
)
RETURNS VARIANT
AS
$$
(
    SELECT
        OBJECT_CONSTRUCT(
            'query', search_query,

            'total_results', COUNT(*),

            'results',
            COALESCE(
                ARRAY_AGG(
                    OBJECT_CONSTRUCT(
                        'product',
                        OBJECT_CONSTRUCT(
                            'product_id', PRODUCT_ID,
                            'product_name', PRODUCT_NAME,
                            'brand', BRAND,
                            'category', CATEGORY,
                            'description', DESCRIPTION,
                            'price', PRICE,
                            'color', COLOR,
                            'size', SIZE,
                            'material', MATERIAL,
                            'in_stock', IN_STOCK,
                            'effective_updated_at',
                                TO_VARCHAR(
                                    EFFECTIVE_UPDATED_AT,
                                    'YYYY-MM-DD HH24:MI:SS'
                                ),
                            'is_merged', IS_MERGED,
                            'merged_product_count', MERGED_PRODUCT_COUNT,
                            'contributing_brands', CONTRIBUTING_BRANDS
                        ),
                        'relevance_score', RELEVANCE_SCORE
                    )
                ) WITHIN GROUP (
                    ORDER BY RELEVANCE_SCORE DESC
                ),
                ARRAY_CONSTRUCT()
            )
        )::VARIANT

    FROM
    (
        SELECT
            PRODUCT_ID,
            PRODUCT_NAME,
            BRAND,
            CATEGORY,
            DESCRIPTION,
            PRICE,
            COLOR,
            SIZE,
            MATERIAL,
            IN_STOCK,
            EFFECTIVE_UPDATED_AT,
            IS_MERGED,
            MERGED_PRODUCT_COUNT,
            CONTRIBUTING_BRANDS,

            ROUND(
                LEAST(
                    1.0,
                    GREATEST(
                        0.0,
                        VECTOR_COSINE_SIMILARITY(
                            AI_EMBED(
                                'snowflake-arctic-embed-m',
                                CONCAT_WS(
                                    ' | ',
                                    BRAND,
                                    PRODUCT_NAME,
                                    CATEGORY,
                                    COALESCE(COLOR, ''),
                                    COALESCE(DESCRIPTION, '')
                                )
                            ),
                            AI_EMBED(
                                'snowflake-arctic-embed-m',
                                search_query
                            )
                        )
                        +
                        IFF(
                            CONTAINS(
                                LOWER(PRODUCT_NAME),
                                LOWER(search_query)
                            ),
                            0.10,
                            0.0
                        )
                    )
                ),
                4
            ) AS RELEVANCE_SCORE

        FROM CATALOG_DB.GOLD.UNIFIED_PRODUCT_CATALOG

        QUALIFY ROW_NUMBER() OVER (
            ORDER BY RELEVANCE_SCORE DESC
        ) <= max_results
    )
)
$$;

-- ==============================================================================
-- 2. ENDPOINT 2: GET /products/{product_id}
-- Returns single product by ID including full column-level source lineage JSON
-- ==============================================================================

CREATE OR REPLACE FUNCTION API_GET_PRODUCT_BY_ID(
    target_product_id VARCHAR
)
RETURNS VARIANT
AS
$$
    SELECT COALESCE(
        (
            SELECT OBJECT_CONSTRUCT(
                'product_id', product_id,
                'product_name', product_name,
                'brand', brand,
                'category', category,
                'description', description,
                'price', price,
                'color', color,
                'size', size,
                'material', material,
                'in_stock', in_stock,
                'effective_updated_at', TO_VARCHAR(effective_updated_at, 'YYYY-MM-DD HH24:MI:SS'),
                'is_merged', is_merged,
                'merged_product_count', merged_product_count,
                'contributing_brands', contributing_brands,
                'source_identifiers', source_identifiers,
                'match_metadata', match_metadata,
                'lineage_metadata', lineage_metadata)
            FROM CATALOG_DB.GOLD.UNIFIED_PRODUCT_CATALOG
            WHERE product_id = target_product_id
            LIMIT 1
        ),
        OBJECT_CONSTRUCT('status_code', 404,'detail', 'Product ID not found: ' || target_product_id)::VARIANT
    )::VARIANT
$$;

SELECT API_SEARCH_PRODUCTS(
    'Nike Air Max 90',
    5
);

SELECT CATALOG_DB.GOLD.API_GET_PRODUCT_BY_ID(
    'GOLD-e2820447080b'
);

SELECT CATALOG_DB.GOLD.API_GET_PRODUCT_BY_ID(
    'GOLD-INVALID-123'
);








