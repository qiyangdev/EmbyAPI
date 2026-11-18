#!/usr/bin/env python3

import argparse
import json
from pathlib import Path
import urllib.request


SDK_REVISION = "45e73012eddf985dcfe878ca031b500085e16496"
SDK_URL = (
    f"https://raw.githubusercontent.com/MediaBrowser/Emby.SDK/{SDK_REVISION}"
    "/Resources/OpenApi/openapi_v3.json"
)
OUTPUT = Path(__file__).resolve().parents[1] / "Sources/EmbyAPI/openapi.json"

OPERATIONS = {
    "/System/Info/Public": ("get",),
    "/Users/Public": ("get",),
    "/Users/AuthenticateByName": ("post",),
    "/Users/{Id}": ("get",),
    "/Users/{UserId}/Views": ("get",),
    "/Users/{UserId}/Items": ("get",),
    "/Users/{UserId}/Items/{Id}": ("get",),
    "/Users/{UserId}/Items/Resume": ("get",),
    "/Users/{UserId}/Items/Latest": ("get",),
    "/Items": ("get",),
    "/Genres": ("get",),
    "/OfficialRatings": ("get",),
    "/Tags": ("get",),
    "/Years": ("get",),
    "/Shows/{Id}/Seasons": ("get",),
    "/Shows/{Id}/Episodes": ("get",),
    "/Items/{Id}/Images/{Type}": ("get",),
    "/Items/{Id}/Images/{Type}/{Index}": ("get",),
    "/Users/{Id}/Images/{Type}": ("get",),
    "/Items/{Id}/PlaybackInfo": ("get", "post"),
    "/Videos/{Id}/stream": ("get",),
    "/Sessions/Playing": ("post",),
    "/Sessions/Playing/Progress": ("post",),
    "/Sessions/Playing/Stopped": ("post",),
    "/Sessions/Logout": ("post",),
}

CATALOG_SCHEMAS = {
    "CatalogItem": {"type": "object"},
    "CatalogPage": {
        "type": "object",
        "properties": {
            "Items": {"type": "array", "items": {"$ref": "#/components/schemas/CatalogItem"}},
            "TotalRecordCount": {"type": "integer"},
        },
    },
}


def json_only(node):
    if isinstance(node, list):
        return [json_only(value) for value in node]
    if not isinstance(node, dict):
        return node
    return {
        key: json_only(value)
        for key, value in node.items()
        if key not in {"application/xml", "summary", "externalDocs", "x-internal-ref-name"}
        and (key != "description" or "schema" not in node)
    }


def references(node):
    if isinstance(node, dict):
        if "$ref" in node:
            yield node["$ref"]
        for value in node.values():
            yield from references(value)
    elif isinstance(node, list):
        for value in node:
            yield from references(value)


def subset(source):
    paths = {
        path: {method: json_only(source["paths"][path][method]) for method in methods}
        for path, methods in OPERATIONS.items()
    }

    # Catalog items retain extension fields and nulls until the app maps each row.
    for path, model in (
        ("/Items", "CatalogPage"),
        ("/Users/{UserId}/Views", "CatalogPage"),
        ("/Users/{UserId}/Items/{Id}", "CatalogItem"),
    ):
        schema = paths[path]["get"]["responses"]["200"]["content"]["application/json"]
        schema["schema"] = {"$ref": f"#/components/schemas/{model}"}

    # Emby accepts view requests without a preference and applies its server default.
    for parameter in paths["/Users/{UserId}/Views"]["get"]["parameters"]:
        if parameter["name"] == "IncludeExternalContent":
            parameter.pop("required", None)

    # Preserve the optional catalog filters forwarded by the app's existing Emby adapter.
    items = paths["/Items"]["get"]
    for name in ("AudioLanguages", "SubtitleLanguages"):
        if not any(parameter["name"] == name for parameter in items["parameters"]):
            items["parameters"].append({"name": name, "in": "query", "schema": {"type": "string"}})

    # The client middleware supplies Emby authorization on every request.
    login = paths["/Users/AuthenticateByName"]["post"]
    login["parameters"] = [
        parameter for parameter in login["parameters"] if parameter["name"] != "X-Emby-Authorization"
    ]

    # The SDK omits the response schemas for episodes and binary HTTP bodies.
    episodes = paths["/Shows/{Id}/Episodes"]["get"]["responses"]["200"]
    episodes.update(
        description="Episode results.",
        content={"application/json": {"schema": {"$ref": "#/components/schemas/QueryResult_BaseItemDto"}}},
    )
    for path in (
        "/Items/{Id}/Images/{Type}",
        "/Items/{Id}/Images/{Type}/{Index}",
        "/Users/{Id}/Images/{Type}",
        "/Videos/{Id}/stream",
    ):
        responses = paths[path]["get"]["responses"]
        responses["200"] = {
            "description": "Image or video bytes.",
            "content": {"*/*": {"schema": {"type": "string", "format": "binary"}}},
        }
        if path.endswith("/stream"):
            responses["206"] = responses["200"]

    # These streaming parameters are documented separately from the SDK schema.
    stream = paths["/Videos/{Id}/stream"]["get"]
    for name, location in (("MediaSourceId", "query"), ("PlaySessionId", "query"), ("Range", "header")):
        if not any(parameter["name"] == name for parameter in stream["parameters"]):
            stream["parameters"].append({"name": name, "in": location, "schema": {"type": "string"}})

    for path in ("/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped", "/Sessions/Logout"):
        paths[path]["post"]["responses"]["204"] = {"description": "Success with no content."}

    components = {
        "securitySchemes": json_only(source["components"]["securitySchemes"]),
        "schemas": CATALOG_SCHEMAS.copy(),
    }
    pending = list(references(paths))
    while pending:
        ref = pending.pop()
        prefix, group, name = ref.rsplit("/", 2)
        if prefix != "#/components":
            raise ValueError(f"Unsupported reference {ref}")
        definitions = components.setdefault(group, {})
        if name not in definitions:
            definition = json_only(source["components"][group][name])
            definitions[name] = definition
            pending.extend(references(definition))

    return {
        "openapi": source["openapi"],
        "info": {
            "title": source["info"]["title"],
            "version": source["info"]["version"],
            "description": "Subset of the Emby Server OpenAPI document for the Swift client.",
        },
        "paths": paths,
        "components": components,
    }


def main():
    parser = argparse.ArgumentParser(description="Refresh the EmbyAPI OpenAPI snapshot.")
    parser.add_argument("--source", type=Path, help="Use a local Emby OpenAPI 3 JSON document.")
    args = parser.parse_args()
    if args.source:
        source = json.loads(args.source.read_bytes())
    else:
        with urllib.request.urlopen(SDK_URL, timeout=30) as response:
            source = json.load(response)
    OUTPUT.write_text(json.dumps(subset(source), indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
