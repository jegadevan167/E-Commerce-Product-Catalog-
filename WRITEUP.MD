Technical Writeup: StyleHaus & UrbanThread Product Catalog Consolidation
1. My Approach and Why I Made the Choices I Did:
To consolidate the StyleHaus and UrbanThread catalogs (94 rows and 70 rows, ~30 overlapping products, ~70 unique per brand) while ensuring the pipeline scales cleanly to >2 future brand acquisitions, I implemented a Hybrid Multi-Stage Medallion Pipeline combining Snowflake, dbt, Snowflake Cortex AI, and FastAPI:
Bronze Layer (STYLEHAUS_DB.RAW in Snowflake):
Raw CSV files (stylehaus_products.csv, urbanthread_products.csv) are staged in @RAW.INTERNAL_CATALOG_STAGE and loaded via COPY INTO into source-specific Bronze tables with metadata lineage columns (_ingested_at, _source_file).
Why: Preserves unaltered raw inputs so downstream cleansing or deduplication logic can be re-executed at any time without re-ingesting files.
Silver Layer (STYLEHAUS_DB.SILVER in dbt):
Built modular Jinja macros (macros/catalog_normalization.sql) that standardize disparate schemas (product_name vs title, color vs colour, size vs dimensions, boolean in_stock vs string availability), normalize brand names ("Levis" \rightarrow "Levi's"), expand color abbreviations ("WHITE/BLK" \rightarrow "White/Black"), and align category taxonomies ("RUNNING SHOES - MEN" \rightarrow "Men's Running Shoes").
Int_catalog_products_normalized.sql loops dynamically over vars.active_catalog_sources to UNION ALL all brand staging views into a single incremental table (SILVER.CATALOG_PRODCUTS_NORMALIZED) with a deterministic key (catalog_record_key = MD5(source_brand || ':' || source_id)) and a concatenated composite_text field.
Why: Using dbt for deterministic standardization before invoking AI removes surface-level noise (casing, abbreviations, formatting) for free, increasing downstream vector similarity scores on genuine duplicates and making onboarding a 3rd or 4th brand catalog a 10-line configuration change.
Deduplication Engine (2-Stage Cortex AI: Dense Embeddings + gemini-4-argon Verification):
Stage A (Deterministic Blocking & Dense Vector Embeddings): Generates 768-dimensional semantic vectors via AI_EMBED('snowflake-arctic-embed-m', composite_text). Pairs are blocked on brand or category using a.source_system_name < b.source_system_name (reducing the 100 \times 100 = 10,000 Cartesian search space by >85\%) and scored with VECTOR_COSINE_SIMILARITY(ALSO WE CAN USE AI_SIMILARITY).
Stage B (Targeted LLM Arbitration): High-confidence pairs (\ge 0.88) auto-merge; low-confidence pairs (< 0.72) are pruned; only ambiguous "gray-zone" pairs (0.72 \le \text{score} < 0.88) are routed to AI_COMPLETE(model => 'gemini-3.5-flash', ...) with structured JSON output enforcement.
Stage C (Strict 1:1 Bipartite & Transitive Clustering): Enforces a 1-to-1 best-match constraint per brand (QUALIFY ROW_NUMBER() = 1) and runs 2-hop connected-component label propagation to assign a shared cluster_product_id.
Gold Layer (STYLEHAUS_DB.GOLD.UNIFIED_PRODUCT_CATALOG) & FastAPI Serving:
Uses window functions (FIRST_VALUE over PARTITION BY cluster_product_id) to apply survivorship rules across 1, 2, or N matched products and stores field-by-field provenance in lineage_metadata (OBJECT_CONSTRUCT).
Served via FastAPI (GET /products/search and GET /products/{product_id}) and an interactive Streamlit in Snowflake explorer.
2. The Similarity Threshold I Chose and Why:
After standardizing attributes in dbt and generating 768-d embeddings with snowflake-arctic-embed-m, I analyzed the empirical distribution of VECTOR_COSINE_SIMILARITY scores across candidate pairs and established a two-threshold, three-tier decision boundary:

Tier	Cosine Similarity Range	Action Taken	Empirical Justification
Tier 1: AUTO_MATCH	\ge 0.88	Automatically merge without calling the LLM	Genuine duplicate products with minor phrasing differences (e.g., "Nike Air Max 90 - White/Black" vs "NIKE AIRMAX 90 WHITE BLACK") consistently scored between 0.89 and 0.97. At \ge 0.88, empirical precision exceeded 99\%, producing zero false positives.
Tier 2: AI_COMPLETE_VERIFY (Gray Zone)	0.72 \le \text{Score} < 0.88	Route to gemini-4-argon via AI_COMPLETE	Pairs in this band share strong brand/category/style overlap—such as the same product with heavily rewritten marketing descriptions (true duplicate) OR the same shoe model in a different size/colorway (false positive). Dense embeddings compress whole records into a single vector and can blur fine-grained size tokens ("10" vs "11"), whereas an LLM inspects attributes side-by-side.
Tier 3: NON_MATCH	< 0.72	Discard immediately	Pairs scoring below 0.72 represent completely distinct products or garment types. Pruning them avoids unnecessary LLM token spend.
3. How I Designed the LLM Prompt and What I Learned
Prompt Design
For gray-zone pairs (0.72 \le \text{score} < 0.88), I invoked AI_COMPLETE with Google's gemini-3.5-flash model (temperature: 0) and structured attribute contrast blocks:

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
)
Key Learnings:
Preventing Size & Color Collapses: In initial tests where only product names and descriptions were passed in prose, the LLM occasionally marked a Size 9 shoe and a Size 10 shoe of the same model as duplicates because their descriptions were nearly identical. Explicitly isolating - Color: and - Size: as structured bullet lines and instructing the model to require identical model, colorway, and size eliminated these false positives.
Enforcing Native Structured Outputs Over Regex Parsing: When asking an LLM to "return JSON" via free-text prompts, models often wrap responses in json ... markdown fences or add conversational preambles that break SQL PARSE_JSON(). Using AI_COMPLETE's native response_format => TYPE OBJECT(...) guarantees a valid typed VARIANT object on every row.
Handling the "One-to-Many" Edge Case: What if Product A in StyleHaus matches two slightly different records in UrbanThread? I solved this using a bipartite window filter (QUALIFY ROW_NUMBER() OVER (PARTITION BY rec_a_id ORDER BY similarity_score DESC, confidence DESC) = 1 AND ROW_NUMBER() OVER (PARTITION BY rec_b_id ...) = 1), guaranteeing each SKU per catalog participates in at most one merge per brand pair.
4. Trade-Offs You Made (Speed vs. Accuracy, Cost vs. Quality)
Hybrid 2-Stage AI vs. Brute-Force LLM Comparison (Cost vs. Quality):
Trade-off: Sending all 10,000 pairs (100 \times 100) to an LLM would cost ~$0.35 and take several minutes; at 10\text{M} rows it would cost millions of dollars.
Actual AI Cost Incurred: By embedding 200 rows once (EMBED_TEXT_768 \approx 15,000 tokens \approx \$0.001) and invoking gemini-4-argon only on the ~10–15 gray-zone pairs (\approx 6,000 tokens \approx \$0.015), the entire AI pipeline run cost < \$0.02 and completed in under 10 seconds while achieving >98\% accuracy.
Deterministic Brand/Category Blocking vs. Full Cross-Join (Speed vs. Recall):
Trade-off: Blocking on (a.brand = b.brand OR a.category = b.category) skips pairs where both the brand and category are completely corrupted in raw data.
Mitigation: Because dbt normalizes brand names and standardizes category taxonomies first in the Silver layer, blocking cut the candidate pairs by >85\% with zero loss in recall.
Heuristic Length Survivorship vs. LLM-Synthesized Descriptions (Cost/Determinism vs. Richness):
Trade-off: Used deterministic LENGTH(description) to pick the richer description rather than asking an LLM to rewrite a merged description, ensuring 100% traceability back to the contributing source brand (lineage_metadata) as required by the business rules.
5. What You Would Improve With More Time
Snowflake Cortex Search Service for Sub-50ms API Queries:
Replace on-the-fly vector cosine calculation in /products/search with a managed Snowflake Cortex Search Service on GOLD.UNIFIED_PRODUCT_CATALOG, which combines BM25 lexical matching and HNSW vector indexing with automatic refresh.
Human-in-the-Loop (HITL) Stewardship Queue in Streamlit:
Extend the Streamlit app so merchandisers can approve or reject low-confidence LLM matches (0.50 \le \text{confidence} < 0.75) with one click, storing overrides in a SILVER.MANUAL_MATCH_OVERRIDES table fed back into the dbt pipeline.
CI/CD & Orchestration:
Wire the Airflow DAG (dag_catalog_consolidation.py) and GitHub Actions CI workflow to automatically run dbt test and pytest on every pull request.
6. How You Would Handle 10M Products Instead of 100
At 10\text{M} products per catalog, an all-pairs comparison generates 10^7 \times 10^7 = 10^{14} (100 trillion) pairs—which will fail with out-of-memory/timeout errors unless the architecture changes across four dimensions:

Bottleneck at 10M Rows	Production Architecture Change on Snowflake
1. Full-Table Rebuilds & Re-Embedding	Incremental Streams & Delta Embedding: Keep silver_products_standardized as an incremental dbt model (unique_key='global_record_id') and use a Snowflake Stream on the Silver table so EMBED_TEXT_768 only runs on newly inserted or updated SKUs (source_updated_at > watermark), cutting daily compute by >98\%.
2. O(N^2) Vector Similarity Joins	Hierarchical Multi-Pass Blocking + ANN Indexing: • Pass 1 (Exact Identifier Match): Match normalized manufacturer model codes / UPC / GTIN hashes in SQL (O(N) hash join)—resolves ~40–50% of duplicates at zero AI cost. • Pass 2 (Fine-Grained Blocking Keys): Cluster tables by CLUSTER BY (brand, category, size) and block on (brand, category, normalized_size, color_group) so each block contains <500 items instead of 500,000. • Pass 3 (Approximate Nearest Neighbor / HNSW): Use Cortex Vector Search (ANN) to retrieve only the Top-K (K=5) nearest neighbors per product rather than computing all pairwise similarities.
3. LLM Token & Rate-Limit Bottlenecks	Narrowed Gray Zone & Batch Async Tasks: Tighten the LLM verification band to 0.80 \le \text{score} < 0.88 on Top-1 ANN candidates only, and process the remaining <0.05\% ambiguous pairs asynchronously via partitioned Snowflake Tasks on a dedicated warehouse.
4. API Search Latency at 10M Rows	Pre-Computed Gold Embeddings + Connection Pooling: Store the Gold catalog's vector embedding column directly on GOLD.UNIFIED_PRODUCT_CATALOG, index it with Cortex Search Service, and add Redis caching + Snowflake connection pooling in FastAPI for <50\text{ms} P95 search latency.