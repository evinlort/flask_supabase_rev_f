import os

from dotenv import load_dotenv
from flask import Flask, jsonify, render_template

load_dotenv()

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_PUBLIC_KEY = os.environ["SUPABASE_PUBLIC_KEY"]

app = Flask(__name__)


@app.get("/")
def index():
    return render_template("index.html")


@app.get("/api/config")
def config():
    # Public/publishable Supabase key. Access control is enforced by Supabase Auth + RLS.
    return jsonify(
        {
            "supabaseUrl": SUPABASE_URL,
            "supabaseKey": SUPABASE_PUBLIC_KEY,
        }
    )


@app.get("/api/health")
def health():
    return jsonify({"status": "ok"})


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=True)
