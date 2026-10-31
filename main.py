
import os
import json

import snowflake.connector
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query

# Load environment variables
load_dotenv()

# Initialize FastAPI
app = FastAPI(
    title="E-Commerce Product Catalog API",
    description="Semantic product search and product details with source lineage.",
    version="1.0.0"
)


# 1. Create Snowflake connection
def get_snowflake_connection():

    required_variables = [
        "SNOWFLAKE_ACCOUNT",
        "SNOWFLAKE_USER",
        "SNOWFLAKE_PASSWORD",
        "SNOWFLAKE_WAREHOUSE"
    ]

    missing = [
        key for key in required_variables
        if not os.getenv(key)
    ]

    if missing:
        raise RuntimeError(
            f"Missing environment variables: {', '.join(missing)}"
        )

    return snowflake.connector.connect(
        account=os.getenv("SNOWFLAKE_ACCOUNT"),
        user=os.getenv("SNOWFLAKE_USER"),
        password=os.getenv("SNOWFLAKE_PASSWORD"),
        warehouse=os.getenv("SNOWFLAKE_WAREHOUSE"),
        database=os.getenv("SNOWFLAKE_DATABASE", "CATALOG_DB"),
        schema=os.getenv("SNOWFLAKE_SCHEMA", "GOLD")
    )


# 2. Execute Snowflake UDF and retrieve JSON
def execute_snowflake_query(sql, params):

    connection = None
    cursor = None

    try:
        connection = get_snowflake_connection()
        cursor = connection.cursor()

        cursor.execute(sql, params)

        row = cursor.fetchone()

        if row is None:
            return None

        result = row[0]

        if isinstance(result, str):
            return json.loads(result)

        return result

    except Exception as exc:
        print("Snowflake query error:", str(exc))

        raise HTTPException(
            status_code=502,
            detail="Unable to retrieve data from Snowflake."
        )

    finally:
        if cursor is not None:
            cursor.close()

        if connection is not None:
            connection.close()


# 3. Health check
@app.get("/health")
def health_check():
    return {
        "status": "API is running",
        "application": "E-Commerce Product Catalog"
    }


# 4. Endpoint 1: Semantic product search
@app.get("/products/search")
def search_products(
    q: str = Query(
        ...,
        min_length=2,
        description="Search products by name or description"
    ),
    limit: int = Query(
        10,
        ge=1,
        le=50
    )
):

    result = execute_snowflake_query(
        """
        SELECT CATALOG_DB.GOLD.API_SEARCH_PRODUCTS(%s, %s)
        """,
        (q, limit)
    )

    if result is None:
        return {
            "query": q,
            "total_results": 0,
            "results": []
        }

    return result


# 5. Endpoint 2: Get product by ID
@app.get("/products/{product_id}")
def get_product_by_id(product_id: str):

    result = execute_snowflake_query(
        """
        SELECT CATALOG_DB.GOLD.API_GET_PRODUCT_BY_ID(%s)
        """,
        (product_id,)
    )

    if result is None:
        raise HTTPException(
            status_code=404,
            detail="Product not found"
        )

    if result.get("status_code") == 404:
        raise HTTPException(
            status_code=404,
            detail=result.get("detail")
        )

    return result
