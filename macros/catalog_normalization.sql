{% macro normalize_brand(col_expr) %}
    CASE 
        WHEN LOWER({{ col_expr }}) LIKE '%nike%' THEN 'Nike'
        WHEN LOWER({{ col_expr }}) LIKE '%adidas%' THEN 'Adidas'
        WHEN LOWER({{ col_expr }}) LIKE '%levi%' THEN 'Levi''s'
        WHEN LOWER({{ col_expr }}) LIKE '%patagonia%' THEN 'Patagonia'
        WHEN LOWER({{ col_expr }}) LIKE '%zara%' THEN 'Zara'
        WHEN LOWER({{ col_expr }}) LIKE '%north face%' THEN 'The North Face'
        WHEN LOWER({{ col_expr }}) LIKE '%lululemon%' THEN 'Lululemon'
        WHEN LOWER({{ col_expr }}) LIKE '%puma%' THEN 'Puma'
        WHEN LOWER({{ col_expr }}) LIKE '%new balance%' THEN 'New Balance'
        WHEN LOWER({{ col_expr }}) LIKE '%under armour%' THEN 'Under Armour'
        ELSE INITCAP(TRIM({{ col_expr }}))
    END
{% endmacro %}

{% macro normalize_category(col_expr) %}
    CASE 
        WHEN UPPER({{ col_expr }}) LIKE '%RUNNING SHOES%' THEN 'Men''s Running Shoes'
        WHEN UPPER({{ col_expr }}) LIKE '%ATHLETIC FOOTWEAR%' THEN 'Women''s Athletic Shoes'
        WHEN UPPER({{ col_expr }}) LIKE '%JACKET%' OR UPPER({{ col_expr }}) LIKE '%OUTERWEAR%' THEN 'Men''s Outerwear'
        WHEN UPPER({{ col_expr }}) LIKE '%DRESS%' THEN 'Women''s Dresses'
        WHEN UPPER({{ col_expr }}) LIKE '%STREETWEAR%' THEN 'Unisex Streetwear'
        WHEN UPPER({{ col_expr }}) LIKE '%JEAN%' OR UPPER({{ col_expr }}) LIKE '%DENIM%' THEN 'Men''s Denim'
        WHEN UPPER({{ col_expr }}) LIKE '%ACTIVEWEAR%' OR UPPER({{ col_expr }}) LIKE '%FITNESS%' THEN 'Women''s Activewear'
        WHEN UPPER({{ col_expr }}) LIKE '%ACCESSOR%' OR UPPER({{ col_expr }}) LIKE '%BAG%' THEN 'Accessories'
        ELSE INITCAP(TRIM({{ col_expr }}))
    END
{% endmacro %}

{% macro normalize_color(col_expr) %}
    CASE 
        WHEN UPPER(TRIM({{ col_expr }})) IN ('WHITE/BLK', 'WHITE / BLACK', 'WHT/BLK') THEN 'White/Black'
        WHEN UPPER(TRIM({{ col_expr }})) IN ('NVY', 'NAVY', 'NAVY BLUE') THEN 'Navy Blue'
        WHEN UPPER(TRIM({{ col_expr }})) IN ('H-GREY', 'HEATHER GREY', 'GREY', 'HEATHER GRAY') THEN 'Heather Grey'
        WHEN UPPER(TRIM({{ col_expr }})) IN ('OLV GRN', 'OLIVE', 'OLIVE GREEN') THEN 'Olive Green'
        WHEN UPPER(TRIM({{ col_expr }})) IN ('ALL BLACK', 'TRIPLE BLACK', 'BLK') THEN 'Triple Black'
        WHEN UPPER(TRIM({{ col_expr }})) IN ('RED / CRIMSON', 'CRIMSON', 'CRIMSON RED', 'RED') THEN 'Crimson Red'
        WHEN UPPER(TRIM({{ col_expr }})) IN ('BEIGE/SAND', 'SAND', 'BEIGE', 'SAND BEIGE') THEN 'Sand Beige'
        ELSE INITCAP(TRIM({{ col_expr }}))
    END
{% endmacro %}

{% macro normalize_size(col_expr) %}
    CASE 
        WHEN UPPER(TRIM({{ col_expr }})) IN ('SIZE SMALL', 'S', 'SMALL') THEN 'S'
        WHEN UPPER(TRIM({{ col_expr }})) IN ('MEDIUM (US)', 'M', 'MED', 'MEDIUM') THEN 'M'
        WHEN UPPER(TRIM({{ col_expr }})) IN ('LARGE - L', 'L', 'LARGE') THEN 'L'
        WHEN UPPER(TRIM({{ col_expr }})) IN ('US XL', 'XL', 'EXTRA LARGE') THEN 'XL'
        WHEN REGEXP_LIKE(UPPER(TRIM({{ col_expr }})), 'US *[0-9]+([.][0-9]+)?')
            THEN REGEXP_SUBSTR(UPPER(TRIM({{ col_expr }})), 'US *([0-9]+([.][0-9]+)?)', 1, 1, 'e', 1)
        WHEN REGEXP_LIKE(UPPER(TRIM({{ col_expr }})), 'W[0-9]+ */ *L[0-9]+')
            THEN CONCAT(REGEXP_SUBSTR(UPPER(TRIM({{ col_expr }})), 'W([0-9]+)', 1, 1, 'e', 1), 'x',
                    REGEXP_SUBSTR(UPPER(TRIM({{ col_expr }})), 'L([0-9]+)', 1, 1, 'e', 1))
        ELSE TRIM({{ col_expr }})
    END
{% endmacro %}

{% macro normalize_material(col_expr) %}
    CASE 
        WHEN REGEXP_LIKE(LOWER(TRIM({{ col_expr }})), 'full[- ]grain leather') THEN 'Full-Grain Leather'
        WHEN LOWER(TRIM({{ col_expr }})) IN ('smooth leather', 'soft leather', 'italian leather', 'lamb leather', 'leather') 
            THEN INITCAP(TRIM({{ col_expr }}))
        WHEN LOWER(TRIM({{ col_expr }})) IN ('nubuck leather', 'premium nubuck leather', 'oiled nubuck leather') 
            THEN 'Nubuck Leather'
        WHEN LOWER(TRIM({{ col_expr }})) IN ('suede', 'suede upper', 'suede leather') THEN 'Suede'
        WHEN LOWER(TRIM({{ col_expr }})) IN ('leather, suede toe', 'leather/suede', 'suede/leather') 
            THEN 'Leather/Suede'
        WHEN LOWER(TRIM({{ col_expr }})) IN ('mesh upper', 'mesh textile', 'engineered mesh', 'hypoknit upper', 'primeknit upper', 'primeknit') 
            THEN CASE
                WHEN LOWER(TRIM({{ col_expr }})) LIKE '%primeknit%' THEN 'Primeknit'
                WHEN LOWER(TRIM({{ col_expr }})) LIKE '%hypoknit%' THEN 'Hypoknit'
                ELSE 'Mesh'
            END
        WHEN LOWER(TRIM({{ col_expr }})) IN ('mesh, leather upper', 'mesh, leather', 'mesh/leather', 'pigskin/mesh', 'pigskin, mesh')
            THEN CASE
                WHEN LOWER(TRIM({{ col_expr }})) LIKE '%pigskin%' THEN 'Pigskin/Mesh'
                ELSE 'Mesh/Leather'
            END
        WHEN LOWER(TRIM({{ col_expr }})) IN ('textile synthetic', 'textile/synthetic', 'synthetic/mesh', 'neoprene/synthetic') 
            THEN INITCAP(TRIM({{ col_expr }}))
        WHEN REGEXP_LIKE(LOWER(TRIM({{ col_expr }})), '^[0-9]+% cotton denim$')
            OR LOWER(TRIM({{ col_expr }})) IN ('cotton denim', 'organic cotton denim', 'japanese selvedge denim')
            THEN 'Cotton Denim'
        WHEN LOWER(TRIM({{ col_expr }})) IN ('100% cotton', 'organic cotton', 'stretch cotton', 'heavyweight cotton', 'cotton')
            THEN 'Pure Cotton'
        WHEN LOWER(TRIM({{ col_expr }})) IN ('cotton mesh', 'cotton canvas', 'cotton duck canvas', 'organic cotton canvas')
            THEN 'Cotton Canvas/Mesh'
        WHEN LOWER(TRIM({{ col_expr }})) IN ('cotton poly fleece', 'cotton/polyester fleece', 'cotton fleece', 'organic cotton fleece', 'recycled fleece', 'heavyweight fleece', 'mtr fleece', 'french terry cotton')
            THEN 'Cotton/Polyester Fleece'
        WHEN LOWER(TRIM({{ col_expr }})) IN ('cotton twill', 'poly cotton twill', 'polyester/cotton twill', 'washed cotton oxford', 'cotton poplin', 'cotton flannel', 'combed cotton jersey', '100% cotton jersey', 'pique cotton', 'petit pique cotton')
            THEN 'Cotton Textile'
        WHEN LOWER(TRIM({{ col_expr }})) IN ('ripstop nylon shell', 'nylon ripstop', 'recycled ripstop nylon', 'recycled ripstop', 'polyester ripstop')
            THEN 'Ripstop'
        WHEN LOWER(TRIM({{ col_expr }})) IN ('recycled nylon', 'nylon', 'silverescent nylon', 'pro-tek nylon', 'nylon suede', 'nylon laque')
            THEN 'Nylon'
        WHEN LOWER(TRIM({{ col_expr }})) IN ('recycled polyester', '100% polyester', 'polyester', 'polyester/viscose', 'polyester elastane', '98% cotton 2% elastane', '95% cotton 5% elastane')
            THEN CASE
                WHEN LOWER(TRIM({{ col_expr }})) LIKE '%elastane%' THEN 'Cotton/Elastane Blend'
                ELSE 'Polyester'
            END
        WHEN LOWER(TRIM({{ col_expr }})) IN ('100% linen') THEN 'Linen'
        WHEN LOWER(TRIM({{ col_expr }})) IN ('100% virgin wool', '100% merino wool') THEN 'Wool'
        WHEN LOWER(TRIM({{ col_expr }})) IN ('twinface sheepskin') THEN 'Sheepskin'
        WHEN LOWER(TRIM({{ col_expr }})) IN ('arctic tech', 'arctic tech shell') THEN 'Arctic Tech'
        WHEN LOWER(TRIM({{ col_expr }})) IN ('recycled tpe laminate', 'texapore/microguard', 'tyono/coreloft', 'warpstreme')
            THEN INITCAP(TRIM({{ col_expr }}))
        WHEN LOWER(TRIM({{ col_expr }})) IN ('metal frame, crystal lens', 'metal/crystal') THEN 'Metal/Crystal'
        WHEN LOWER(TRIM({{ col_expr }})) IN ('o-matter frame', 'acetate/crystal', 'stainless steel/leather')
            THEN INITCAP(TRIM({{ col_expr }}))
        ELSE INITCAP(TRIM({{ col_expr }}))
    END
{% endmacro %}

{% macro normalize_boolean_stock(col_expr) %}
    CASE 
        WHEN UPPER(TRIM(TO_VARCHAR({{ col_expr }}))) IN ('TRUE', 'IN STOCK', '1', 'AVAILABLE', 'YES') THEN TRUE
        ELSE FALSE
    END
{% endmacro %}

{% macro catalogs_standardization(company_name, source_call, col_map) %}

{% set id_col = col_map['id'] %}
{% set name_col = col_map['name'] %}
{% set price_col = col_map['price'] %}

SELECT
    MD5(CONCAT('{{ company_name }}', ':', TRIM(TO_VARCHAR({{ id_col }})))) AS catalog_record_key,
    '{{ company_name }}'::VARCHAR(50) AS source_system_name,
    TRIM(TO_VARCHAR({{ id_col }}))::VARCHAR(100) AS source_product_id,
    {{ col_map.get('name_transform', 'TRIM(' ~ name_col ~ ')') }}::VARCHAR(500) AS product_name,
    LOWER(REGEXP_REPLACE(TRIM({{ name_col }}), '[^a-zA-Z0-9 ]', ''))::VARCHAR(500) AS normalized_product_name,
    ({{ normalize_brand(col_map['brand']) }})::VARCHAR(200) AS brand_name,
    ({{ normalize_category(col_map['category']) }})::VARCHAR(200) AS product_category,
    TRIM({{ col_map['description'] }})::TEXT AS product_description,
    COALESCE(TRY_TO_DECIMAL(TO_VARCHAR({{ col_map['price'] }}), 10, 2), 0.00)::NUMBER(10, 2) AS product_price,
    ({{ normalize_color(col_map['color']) }})::VARCHAR(100) AS product_color,
    ({{ normalize_size(col_map['size']) }})::VARCHAR(50) AS size_value,
    ({{ normalize_material(col_map['material']) }})::VARCHAR(200) AS material_description,
    ({{ normalize_boolean_stock(col_map['in_stock']) }})::BOOLEAN AS is_in_stock,
    TRY_TO_TIMESTAMP_NTZ(TO_VARCHAR({{ col_map['updated_at'] }})) AS source_last_modified_at
FROM {{ source_call }}
WHERE {{ col_map['id'] }} IS NOT NULL
{% endmacro %}