import os

from dotenv import load_dotenv
from flask import Flask, jsonify, render_template

from translations import LANGUAGES, TRANSLATIONS

load_dotenv()

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_PUBLIC_KEY = os.environ["SUPABASE_PUBLIC_KEY"]

app = Flask(__name__)


def render_localized(lang):
    other_lang = "en" if lang == "he" else "he"
    return render_template(
        "index.html",
        lang=lang,
        dir=LANGUAGES[lang]["dir"],
        t=TRANSLATIONS[lang],
        other_lang=other_lang,
        other_url=LANGUAGES[other_lang]["url"],
    )


@app.get("/")
def index():
    return render_localized("he")


@app.get("/en/")
def index_en():
    return render_localized("en")


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
