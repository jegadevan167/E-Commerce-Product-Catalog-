# E-Commerce-Product-Catalog-Consolidation-Pipeline
** STYLEHAUS + URBANTHREAD UNIFIED CATALOG ** 
|| SNOWFLAKE, DBT, CORTEX AI ('GEMINI-FLASH-3.5'), FASTAPI || 
& STREAMLIT (EXTRA- SNOWFLAKE INTERNAL FEATURE)||
  
Building an end-to-end data engineering pipeline to ingest, clean, and standardize product catalogs from two brands. Uses AI-powered similarity matching to detect and resolve duplicates, creates a unified gold catalog with source-level data lineage, and exposes RESTful APIs using FastAPI for efficient product search and retrieval.

# PREREQUISITES
	1. Snowflake account with Cortex AI enabled.
	2. Python 3.13.17 version and dbt-snowflake connection.

# STEP-1: INGEST RAW CSVs INTO SNOWFLAKE(RAW/BRONZE)

?Open snowflake_pipeline.sql in a Snowflake Snowsight Worksheet and run Section 1 to create CATALOG_WH, CATALOG_DB, schemas (RAW, SILVER, GOLD), File Format, @RAW.INTERNAL_CATALOG_STAGE, and the raw tables (STYLEHAUS_PRODUCTS, URBANTHREAD_PRODUCTS).

?Upload stylehaus_products.csv and urbanthread_products.csv to @STYLEHAUS_DB.RAW.INTERNAL_CATALOG_STAGE via Snowsight UI (Add files into Stage + load Files).

?Run the COPY INTO commands in the same snowflake_pipeline.sql and verify respective rows in each table.

# STEP-2: CLEANSE & STANDARDIZE VIA DBT (SILVER)

Configure the snowflake credentials in project.yml file. we can use dbt run, dbt build, dbt test to individually run a model or to run the whole project as well.

Built modular Jinja macros (macros/catalog_normalization.sql) that standardize disparate schemas (product_name vs title, color vs colour, size vs dimensions, boolean in_stock vs string availability), normalize brand names ("Levis" \rightarrow "Levi's"), expand color abbreviations ("WHITE/BLK" \rightarrow "White/Black"), and align category taxonomies ("RUNNING SHOES - MEN" \rightarrow "Men's Running Shoes").

Int_catalog_products_normalized.sql loops dynamically over vars.active_catalog_sources to UNION ALL all brand staging views into a incremental table (SILVER.CATALOG_PRODCUTS_NORMALIZED) with a deterministic key (catalog_record_key = MD5(source_brand || ':' || source_id)) and a concatenated composite_text field.

# STEP-3: DEDUPLICATE VIA SNOWFLAKE CORTEX AI 
(EMBEDDINGS + GEMINI-3.5-FLASH) 

Generate 768-d vectors in SILVER.PRODUCT_EMBEDDINGS using AI_EMBED and Block Candidate pairs by brand and category and compute VECTOR_COSINE_SIMILARITY / AI_SIMILARITY and evaluate the gray-zone candidates in SILVER.AI_REVIEW_RESULTS using AI_COMPLETE(model => 'gemini-3.5-flash', ... & finally enforce strict 1:1 bipartite matching and assign cluster_product_id.

# STEP-4: CREATE THE UNIFIED CATALOG WITH FIELD LINEAGE (GOLD)

Create CATALOG_DB.GOLD.UNIFIED_PRODUCT_CATALOG with survivorship rules:
	1. Longer, more descriptive product_name and description
	2. ?Lower price
	3. ?Most recently updated value for brand, category, color, 		size, material, and in_stock
	4. ?Granular field-level provenance in lineage_metadata 			(JSON/VARIANT).

# STEP-5: RUNNING THE FASTAPI APPLICATION USING PYTHON (LOCALLY)

Build and Run Standalone FASTAPI server locally using WINDOWS POWERSHELL (refer python-fastapi.md file).

INTERACTIVE UI:
http://127.0.0.1:8000/docs

SEARCH ENDPOINT: 
GET http://127.0.0.1:8000/products/search?q=Nike+Air+Max&limit=5
?

GET PRODUCT + LINEAGE ENDPOINT: 
GET http://127.0.0.1:8000/products/{product_id}

*** EXTRA ***

# STEP-6: STREAMLIT PYHTON APPLICATION (SNOWFLAKE)

In Snowflake Snowsight, I used STREAMLIT to create a streamli_app that uses python, (PROJECT -> STREAMLIT -> STREAMLIT APP (SELECT CATALOG_DB.GOLD AND CATALOG_WH), results in providing a Visual UI inside Snowsight itself. 

 
 

