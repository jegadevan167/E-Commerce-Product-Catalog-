{{
    config(
        materialized='view',
        alias='STYLEHAUS_PRODUCTS_NORMALIZED'
    )
}}

{{ catalogs_standardization(
    company_name = "STYLEHAUS", 
    source_call = source("SF_Source", "STYLEHAUS_PRODUCTS"), 
    col_map = {
        'id': 'SKU',
        'name': 'PRODUCT_NAME',
        'name_transform': 'TRIM(PRODUCT_NAME)',
        'brand': 'BRAND',
        'category': 'CATEGORY',
        'description': 'DESCRIPTION',
        'price': 'PRICE',
        'color': 'COLOR',
        'size': 'SIZE',
        'material': 'MATERIAL',
        'in_stock': 'IN_STOCK',
        'updated_at': 'UPDATED_AT'
    }
) }}