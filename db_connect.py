import os
from urllib.parse import quote_plus

from dotenv import load_dotenv
from sqlalchemy import create_engine

# Load credentials from the hidden local .env file
load_dotenv()


def connect_to_db():
    """
    Establishes and returns a reusable SQLAlchemy Engine factory
    that automatically handles its own connection pools.
    """
    try:
        # URL encode username and password to handle special characters cleanly
        user = quote_plus(os.getenv("DB_USER", ""))
        password = quote_plus(os.getenv("DB_PASSWORD", ""))
        host = os.getenv("DB_HOST", "localhost")
        port = os.getenv("DB_PORT", "5432")
        dbname = os.getenv("DB_NAME", "")

        # Formulate standard SQLAlchemy connection URL
        db_url = f"postgresql://{user}:{password}@{host}:{port}/{dbname}"

        # Create and return the engine factory object
        engine = create_engine(db_url)
        return engine

    except Exception as error:
        print(f"Error initializing SQLAlchemy Engine: {error}")
        return None
