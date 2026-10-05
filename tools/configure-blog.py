#!/usr/bin/env python3
"""Validate and select the JSON profile bundled in the next iOS build."""
from pathlib import Path
import argparse
import json
import re
from html.parser import HTMLParser
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent.parent

PREVIEW_FIELDS = {"content", "title", "description", "date", "dateJapanese", "dateISO8601", "tags", "tagText", "siteTitle", "siteDescription"}

def validate_preview(text):
    if len(text.encode("utf-8")) > 2_000_000:
        raise ValueError("Preview template must be at most 2 MB")
    if text.count("{{content}}") != 1 or not re.search(r"<head(?:\s[^>]*)?>", text, re.I) or not re.search(r"<body(?:\s[^>]*)?>", text, re.I):
        raise ValueError("Preview template needs head, body and exactly one {{content}}")
    unknown = set(re.findall(r"\{\{([A-Za-z][A-Za-z0-9]*)\}\}", text)) - PREVIEW_FIELDS
    if unknown:
        raise ValueError("Unknown preview placeholders: " + ", ".join(sorted(unknown)))
    class Check(HTMLParser):
        def handle_starttag(self, tag, attrs):
            values = dict(attrs)
            if tag == "base" or tag == "meta" and values.get("http-equiv", "").lower() == "refresh":
                raise ValueError("Preview template must not contain base or meta refresh")
    Check().feed(text)
    return text

def validate(p):
    def require(condition, message):
        if not condition:
            raise ValueError(message)
    def path(value, empty=False):
        return isinstance(value, str) and (empty and value == "" or all(
            part and part not in {".", ".."} and all(c.isalnum() or c in "_.-" for c in part)
            for part in value.split("/")))
    require(p["schemaVersion"] == 1, "schemaVersion must be 1")
    require(path(p["articleDirectory"], True) and path(p["imageDirectory"], True), "Use repository-relative storage directories")
    require(p["imageReferenceStyle"] in {"site-relative", "absolute"}, "Supported image reference styles: site-relative, absolute")
    public = p["imagePublicPath"]
    require(isinstance(public, str) and public.startswith("/") and (public == "/" or path(public[1:])), "imagePublicPath must start with /, without a trailing slash")
    extensions = p["articleExtensions"]
    require(isinstance(extensions, list) and extensions and len(set(extensions)) == len(extensions) and all(x in {"md", "markdown"} for x in extensions), "Supported extensions: md, markdown")
    require(all(path(x) and "/" not in x for x in p["excludedArticleNames"]), "Invalid excluded article name")
    template = p["filenameTemplate"]
    sample = re.sub(r"\{(?:id|date|year|month|day)\}", "01", template)
    require(template.count("{id}") == 1 and path(sample) and sample.rsplit(".", 1)[-1] in extensions, "filenameTemplate must contain one {id} and a supported extension")
    f = p["frontMatter"]
    require(f["format"] in {"yaml", "toml", "json"}, "Supported formats: yaml, toml, json")
    require(f["dateStyle"] in {"date", "iso8601", "jekyll"}, "Supported date styles: date, iso8601, jekyll")
    require(isinstance(f["timeZone"], str) and f["timeZone"], "Set an IANA time zone")
    ZoneInfo(f["timeZone"])
    require(isinstance(f["requireDescription"], bool), "requireDescription must be boolean")
    keys = [f["fields"][k] for k in ["title", "date"]]
    keys += [f["fields"].get(k) for k in ["description", "tags"] if f["fields"].get(k) is not None]
    require(len(set(keys)) == len(keys), "Editable field names must not repeat")
    require(isinstance(f["extra"], dict), "extra must be an object")
    require(all(isinstance(k, str) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", k) for k in keys + list(f["extra"])), "Use simple top-level field names")
    require(not set(keys).intersection(f["extra"]), "extra must not override editable fields")
    require(not f["requireDescription"] or f["fields"].get("description"), "Required description needs a field name")
    require(all(isinstance(v, (str, bool)) or isinstance(v, (int, float)) and abs(v) <= 9007199254740991
                or isinstance(v, list) and all(isinstance(x, str) for x in v) for v in f["extra"].values()), "extra supports strings, booleans, safe numbers and string arrays")
    if "preview" in p:
        preview = p["preview"]
        require(isinstance(preview, dict) and set(preview) == {"templateFile"} and isinstance(preview["templateFile"], str) and preview["templateFile"].strip(), "preview requires templateFile")
    return p

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", type=Path, nargs="?", default=ROOT / "ios/cocoWriter/BlogProfile.json")
    parser.add_argument("--check", action="store_true", help="Validate without modifying files")
    parser.add_argument("--blog", type=Path, help="Also apply to an existing standalone cocoWriter blog template")
    parser.add_argument("--preview-template", type=Path, help="HTML shell with {{content}}; overrides preview.templateFile")
    args = parser.parse_args()
    try:
        profile = validate(json.loads(args.profile.read_text()))
        preview_path = args.preview_template
        if preview_path is None and "preview" in profile:
            preview_path = args.profile.resolve().parent / profile["preview"]["templateFile"]
        preview_text = validate_preview(preview_path.read_text(encoding="utf-8")) if preview_path else ""
        # Theme changes do not change an article's saved storage/Front Matter profile.
        profile = {key: value for key, value in profile.items() if key != "preview"}
        targets = [ROOT / "ios/cocoWriter/BlogProfile.json"]
        if args.blog:
            blog = args.blog.resolve()
            if not (blog / "tools/profile.mjs").is_file() or not (blog / "site.config.json").is_file():
                raise ValueError("--blog must name a cocoWriter blog template; existing Jekyll/Hugo projects need only the iOS profile")
            targets.append(blog / "blog-profile.json")
        if not args.check:
            text = json.dumps(profile, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
            for target in targets:
                target.write_text(text)
            (ROOT / "ios/cocoWriter/BlogPreviewTemplate.html").write_text(preview_text, encoding="utf-8")
            if args.blog:
                (blog / profile["articleDirectory"]).mkdir(parents=True, exist_ok=True)
            print("Applied profile. Rebuild the app. Existing articles/images have not been moved.")
        else:
            print("PASS:", args.profile)
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(1, "Invalid blog profile: " + str(error) + "\n")

if __name__ == "__main__":
    main()
