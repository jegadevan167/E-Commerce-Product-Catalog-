# Import python packages

import os
import json
import pandas as pd
import streamlit as st

st.set_page_config(page_title="E-Commerce Product Catalog", layout="wide")

# 1. Connect to Snowflake
try:
    conn = st.connection("snowflake", ttl=os.getenv("SNOWFLAKE_CONNECTION_TTL"))
    session = conn.session()
except Exception:
    from snowflake.snowpark.context import get_active_session
    session = get_active_session()

session.sql("USE DATABASE CATALOG_DB").collect()
session.sql("USE SCHEMA GOLD").collect()
session.sql("USE WAREHOUSE CATALOG_WH").collect()

# 2. Header & Executive KPI Metrics
st.title("🛍️ E-Commerce Unified Product Catalog")
st.caption("Powered by dbt Silver | Snowflake Cortex AI (snowflake-arctic-embed-m) | AI-based Product Matching | FastAPI Endpoints")

stats = session.sql("""
    SELECT
        COUNT(*) AS total_products,
        COUNT_IF(is_merged = TRUE) AS merged_products,
        COUNT_IF(is_merged = FALSE) AS unique_products
    FROM CATALOG_DB.GOLD.UNIFIED_PRODUCT_CATALOG
""").collect()[0]

col1, col2, col3 = st.columns(3)
col1.metric("Total Gold Products", stats["TOTAL_PRODUCTS"])
col2.metric("Merged Duplicate Products", stats["MERGED_PRODUCTS"])
col3.metric("Unique Single-Source Products", stats["UNIQUE_PRODUCTS"])

st.divider()

# 3. Interactive Endpoint 1: GET /products/search
st.subheader("🔍 Endpoint 1: `GET /products/search` (Semantic Relevance Ranking)")

s_col1, s_col2 = st.columns([3, 1])

with s_col1:
    search_query = st.text_input(
        "Search Gold Catalog by Product Name:",
        value="Nike Air Max"
    )

with s_col2:
    limit = st.slider(
        "Max Results (`limit`)",
        min_value=1,
        max_value=20,
        value=5
    )

search_data = {}

if search_query:
    raw_search = session.sql(
        """
        SELECT CATALOG_DB.GOLD.API_SEARCH_PRODUCTS(?, ?)
        """,
        params=[search_query, limit]
    ).collect()[0][0]

    search_data = json.loads(raw_search) if isinstance(raw_search, str) else raw_search

    results = search_data.get("results", [])

    if results:
        rows = []

        for r in results:
            p = r["product"]

            rows.append({
                "Relevance Score": r["relevance_score"],
                "Product ID": p["product_id"],
                "Product Name": p["product_name"],
                "Brand": p["brand"],
                "Category": p["category"],
                "Winning Price ($)": p["price"],
                "Merged?": "✅ Yes" if p["is_merged"] else "Single Source",
                "Contributing Brands": ", ".join(p["contributing_brands"])
            })

        st.dataframe(
            pd.DataFrame(rows),
            use_container_width=True,
            hide_index=True
        )

        with st.expander("View Raw JSON Response (`GET /products/search`)"):
            st.json(search_data)

st.divider()

# 4. Interactive Endpoint 2: GET /products/{product_id}
st.subheader("🧬 Endpoint 2: `GET /products/{product_id}` (Source Lineage Inspector)")

product_list = session.sql("""
    SELECT product_id, product_name, is_merged
    FROM CATALOG_DB.GOLD.UNIFIED_PRODUCT_CATALOG
    ORDER BY is_merged DESC, product_name ASC
""").collect()

options = [
    f"{r['PRODUCT_ID']} — {r['PRODUCT_NAME']} ({'MERGED' if r['IS_MERGED'] else 'UNIQUE'})"
    for r in product_list
]

selected_option = st.selectbox(
    "Select a Gold Product to inspect field-level lineage:",
    options
)

if selected_option:
    selected_id = selected_option.split(" — ")[0]

    raw_detail = session.sql(
        """
        SELECT CATALOG_DB.GOLD.API_GET_PRODUCT_BY_ID(?)
        """,
        params=[selected_id]
    ).collect()[0][0]

    detail_data = json.loads(raw_detail) if isinstance(raw_detail, str) else raw_detail

    d_col1, d_col2 = st.columns([1, 1])

    with d_col1:
        st.markdown("#### Field-by-Field Source Lineage")

        lineage = detail_data.get("lineage_metadata", {})
        lineage_rows = []

        for field_name in [
            "product_name",
            "description",
            "price",
            "brand",
            "category",
            "color",
            "size",
            "material",
            "in_stock"
        ]:
            lineage_rows.append({
                "Catalog Field": field_name,
                "Winning Gold Value": str(detail_data.get(field_name)),
                "Contributed By (Lineage)": lineage.get(field_name, "N/A")
            })

        st.dataframe(
            pd.DataFrame(lineage_rows),
            use_container_width=True,
            hide_index=True
        )

    with d_col2:
        st.markdown("#### Raw JSON Response (`GET /products/{product_id}`)")
        st.json(detail_data)
