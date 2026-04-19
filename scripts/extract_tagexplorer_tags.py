#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


TAG_GROUP_EXPORT_RE = re.compile(r"^export const (\w+): TagGroup = \{$", re.MULTILINE)
NAMED_ARRAY_EXPORT_RE = re.compile(r"export const (\w+): Tag\[\] = \[", re.MULTILINE)
STRING_RE = re.compile(r"""(['"])((?:\\.|(?!\1).)*)\1""")
NAME_RE = re.compile(r"name:\s*'((?:\\.|[^'])*)'")


def decode_js_string(value: str) -> str:
    return bytes(value, "utf-8").decode("unicode_escape")


def title_from_slug(slug: str) -> str:
    text = slug.replace("_-_", " / ").replace("_", " ").replace(" - ", " / ")
    return " ".join(part.capitalize() for part in text.split())


def normalize_tag_for_display(value: str) -> str:
    return value.replace("\\(", "(").replace("\\)", ")").replace("\\'", "'").replace('\\"', '"')


def parse_bracketed_segment(text: str, start_index: int, open_char: str, close_char: str) -> tuple[str, int]:
    depth = 0
    index = start_index
    string_delimiter: str | None = None
    escaped = False

    while index < len(text):
        char = text[index]
        if string_delimiter is not None:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == string_delimiter:
                string_delimiter = None
        else:
            if char in ("'", '"'):
                string_delimiter = char
            elif char == open_char:
                depth += 1
            elif char == close_char:
                depth -= 1
                if depth == 0:
                    return text[start_index : index + 1], index + 1
        index += 1

    raise ValueError(f"Unbalanced {open_char}{close_char} segment")


def parse_named_tag_array(source_text: str, export_name: str) -> list[str]:
    match = re.search(rf"export const {re.escape(export_name)}: Tag\[\] = \[", source_text)
    if not match:
        raise ValueError(f"Could not find array export {export_name}")

    array_segment, cursor = parse_bracketed_segment(source_text, match.end() - 1, "[", "]")
    tags = [decode_js_string(value) for _, value in STRING_RE.findall(array_segment)]

    concat_match = re.search(r"\.concat\(\[", source_text[cursor:])
    if concat_match:
        concat_start = cursor + concat_match.start() + len(".concat(")
        concat_segment, _ = parse_bracketed_segment(source_text, concat_start, "[", "]")
        tags.extend(decode_js_string(value) for value in NAME_RE.findall(concat_segment))

    return tags


def parse_exported_string_array(source_text: str, export_name: str) -> list[str]:
    match = re.search(rf"export const {re.escape(export_name)} = \[", source_text)
    if not match:
        raise ValueError(f"Could not find string array export {export_name}")

    array_segment, _ = parse_bracketed_segment(source_text, match.end() - 1, "[", "]")
    return [decode_js_string(value) for _, value in STRING_RE.findall(array_segment)]


def extract_tag_group_block(source_text: str, export_name: str) -> str:
    starts = list(TAG_GROUP_EXPORT_RE.finditer(source_text))
    for index, match in enumerate(starts):
        if match.group(1) != export_name:
            continue
        start = match.start()
        end = starts[index + 1].start() if index + 1 < len(starts) else len(source_text)
        return source_text[start:end]
    raise ValueError(f"Could not find tag group block for {export_name}")


def extract_property_segment(block: str, property_name: str) -> str | None:
    match = re.search(rf"{re.escape(property_name)}:\s*", block)
    if not match:
        return None

    start = match.end()
    next_match = re.search(r"\n\s*(slug|wikiPage|prompt|tags|fails|portrait):", block[start:])
    end = start + next_match.start() if next_match else len(block)
    return block[start:end].strip().rstrip(",")


def extract_tags_from_property(segment: str, shared_arrays: dict[str, list[str]]) -> list[str]:
    for shared_name, values in shared_arrays.items():
        if re.search(rf"\b{re.escape(shared_name)}\b", segment):
            return list(values)

    tags: list[str] = []
    first_array_match = re.search(r"\[", segment)
    if first_array_match:
        first_array, cursor = parse_bracketed_segment(segment, first_array_match.start(), "[", "]")
        tags.extend(decode_js_string(value) for _, value in STRING_RE.findall(first_array))

        tail = segment[cursor:]
        concat_match = re.search(r"\.concat\(\[", tail)
        if concat_match:
            concat_start = cursor + concat_match.start() + len(".concat(")
            concat_array, _ = parse_bracketed_segment(segment, concat_start, "[", "]")
            tags.extend(decode_js_string(value) for value in NAME_RE.findall(concat_array))

    return tags


def parse_tag_groups(tag_groups_path: Path, shared_arrays: dict[str, list[str]]) -> list[dict]:
    source_text = tag_groups_path.read_text(encoding="utf-8")
    groups: list[dict] = []

    for match in TAG_GROUP_EXPORT_RE.finditer(source_text):
        export_name = match.group(1)
        block = extract_tag_group_block(source_text, export_name)

        slug_match = re.search(r"slug:\s*'((?:\\.|[^'])*)'", block)
        if not slug_match:
            continue

        slug = decode_js_string(slug_match.group(1))
        wiki_match = re.search(r"wikiPage:\s*'((?:\\.|[^'])*)'", block)
        tags_segment = extract_property_segment(block, "tags") or ""
        fails_segment = extract_property_segment(block, "fails")

        tags = extract_tags_from_property(tags_segment, shared_arrays)
        fails = extract_tags_from_property(fails_segment, shared_arrays) if fails_segment else []

        groups.append(
            {
                "exportName": export_name,
                "slug": slug,
                "displayName": title_from_slug(slug),
                "wikiPage": decode_js_string(wiki_match.group(1)) if wiki_match else None,
                "tags": tags,
                "fails": fails,
            }
        )

    return groups


def parse_gens_samples(gens_root: Path) -> dict[str, list[str]]:
    result: dict[str, list[str]] = {}
    if not gens_root.exists():
        return result

    for directory in sorted(path for path in gens_root.iterdir() if path.is_dir()):
        seen: set[str] = set()
        tags: list[str] = []
        for file_path in sorted(directory.iterdir()):
            if not file_path.is_file():
                continue
            stem = file_path.stem
            tag = re.sub(r"_\d+$", "", stem).strip()
            if not tag or tag == "no tag":
                continue
            if tag not in seen:
                seen.add(tag)
                tags.append(tag)
        result[directory.name] = tags

    return result


def parse_artist_tags(artist_tags_path: Path, artist_list_paths: list[Path]) -> dict:
    raw = json.loads(artist_tags_path.read_text(encoding="utf-8"))
    merged_artist_tags: set[str] = set()

    for artist_list_path in artist_list_paths:
        source_text = artist_list_path.read_text(encoding="utf-8")
        export_match = re.search(r"export const (\w+) = \[", source_text)
        if not export_match:
            raise ValueError(f"Could not infer exported array name from {artist_list_path}")
        merged_artist_tags.update(parse_exported_string_array(source_text, export_match.group(1)))

    clean_artists = []
    for normalized in sorted(tag.strip() for tag in merged_artist_tags if tag.strip()):
        if normalized.lower() == "banned artist":
            continue
        stats = raw.get(normalized, {})
        clean_artists.append(
            {
                "tag": normalized,
                "postCount": stats.get("postCount"),
                "faveCount": stats.get("faveCount"),
                "score": stats.get("score"),
                "animaUniqueness": stats.get("animaUniqueness"),
                "ilUniqueness": stats.get("ilUniqueness"),
            }
        )

    clean_artists.sort(key=lambda item: item["tag"].lower())
    return {
        "count": len(clean_artists),
        "tags": [item["tag"] for item in clean_artists],
        "detailed": clean_artists,
    }


def build_output(tag_groups: list[dict], artists: dict, gens_samples: dict[str, list[str]]) -> dict:
    categories = []
    flattened_tags: set[str] = set()

    for group in tag_groups:
        group_tags = group["tags"]
        normalized_tags = [normalize_tag_for_display(tag) for tag in group_tags]
        flattened_tags.update(group_tags)
        observed = gens_samples.get(group["slug"], [])
        observed_set = {normalize_tag_for_display(tag) for tag in observed}
        group_set = set(normalized_tags)

        categories.append(
            {
                **group,
                "tagCount": len(group_tags),
                "displayTags": normalized_tags,
                "sampleTagCount": len(observed),
                "sampleTagsObserved": observed,
                "tagsMissingSampleImages": sorted(group_set - observed_set),
                "sampleOnlyTags": sorted(observed_set - group_set),
            }
        )

    return {
        "summary": {
            "categoryCount": len(categories),
            "categoryTagCount": len(flattened_tags),
            "artistTagCount": artists["count"],
            "totalWildcardCount": len(flattened_tags) + artists["count"],
        },
        "categories": categories,
        "artists": artists,
        "flattenedCategoryTags": sorted(flattened_tags),
    }


def write_wildcard_text_files(output_path: Path, output: dict) -> Path:
    wildcard_root = output_path.with_suffix("")
    categories_dir = wildcard_root / "categories"
    categories_dir.mkdir(parents=True, exist_ok=True)

    for category in output["categories"]:
        category_file = categories_dir / f"{category['slug']}.txt"
        category_file.write_text("\n".join(category["tags"]) + "\n", encoding="utf-8")

    (wildcard_root / "artists.txt").write_text("\n".join(output["artists"]["tags"]) + "\n", encoding="utf-8")
    return wildcard_root


def main() -> None:
    parser = argparse.ArgumentParser(description="Extract a clean wildcard list from tagexplorer sources.")
    parser.add_argument(
        "--tag-groups",
        default="/Users/ivan/Desktop/workbin/code/tagexplorer.github.io/src/tagGroups.ts",
        help="Path to tagexplorer tagGroups.ts",
    )
    parser.add_argument(
        "--nono-words",
        default="/Users/ivan/Desktop/workbin/code/tagexplorer.github.io/src/nonoWords.ts",
        help="Path to tagexplorer nonoWords.ts",
    )
    parser.add_argument(
        "--artist-tags",
        default="/Users/ivan/Desktop/workbin/code/tagexplorer.github.io/src/assets/artistTagsAll.json",
        help="Path to tagexplorer artistTagsAll.json",
    )
    parser.add_argument(
        "--artist-lists",
        nargs="+",
        default=[
            "/Users/ivan/Desktop/workbin/code/tagexplorer.github.io/src/artistTagStrings.ts",
            "/Users/ivan/Desktop/workbin/code/tagexplorer.github.io/src/animaArtistTagStrings.ts",
        ],
        help="Paths to tagexplorer artist tag list source files to merge and dedupe",
    )
    parser.add_argument(
        "--gens-root",
        default="gens",
        help="Path to the local AiGallery gens folder used as a sample cross-check",
    )
    parser.add_argument(
        "--output",
        default="derived/tagexplorer-wildcards.json",
        help="Where to write the extracted wildcard catalog JSON",
    )
    args = parser.parse_args()

    nono_words_path = Path(args.nono_words)
    nono_source = nono_words_path.read_text(encoding="utf-8")
    shared_arrays = {
        export_name: parse_named_tag_array(nono_source, export_name)
        for export_name in ("focusTags", "faceTagsFailsList", "faceTagsList")
    }

    tag_groups = parse_tag_groups(Path(args.tag_groups), shared_arrays)
    artists = parse_artist_tags(Path(args.artist_tags), [Path(path) for path in args.artist_lists])
    gens_samples = parse_gens_samples(Path(args.gens_root))
    output = build_output(tag_groups, artists, gens_samples)

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(output, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    wildcard_root = write_wildcard_text_files(output_path, output)

    print(f"Wrote {output_path}")
    print(f"Wrote wildcard text files under {wildcard_root}")
    print(
        json.dumps(
            {
                "categories": output["summary"]["categoryCount"],
                "categoryTags": output["summary"]["categoryTagCount"],
                "artists": output["summary"]["artistTagCount"],
                "totalWildcards": output["summary"]["totalWildcardCount"],
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
