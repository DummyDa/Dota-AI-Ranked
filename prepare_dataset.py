from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any, Iterable


ORDER_NAMES = {
    1: "MOVE_TO_POSITION",
    2: "MOVE_TO_TARGET",
    3: "ATTACK_MOVE",
    4: "ATTACK_TARGET",
    5: "CAST_POSITION",
    6: "CAST_TARGET",
    7: "CAST_TARGET_TREE",
    8: "CAST_NO_TARGET",
    9: "CAST_TOGGLE",
    10: "HOLD_POSITION",
    11: "TRAIN_ABILITY",
    14: "PICKUP_ITEM",
    15: "PICKUP_RUNE",
    16: "PURCHASE_ITEM",
    17: "SELL_ITEM",
    20: "CAST_TOGGLE_AUTO",
    21: "STOP",
}

CAST_ORDERS = {5, 6, 7, 8, 9, 20}
TARGET_CLICK_ORDERS = {2, 4}
RIGHT_CLICK_SOURCES = {"inferred_right_click", "sampled_held_right_click"}
NO_TARGET_ITEMS = {
    "item_power_treads", "item_phase_boots", "item_magic_stick", "item_magic_wand",
    "item_black_king_bar", "item_mask_of_madness", "item_manta", "item_satanic",
    "item_shadow_blade", "item_silver_edge", "item_dust", "item_smoke_of_deceit",
}


def records(paths: Iterable[Path]) -> Iterable[dict[str, Any]]:
    for path in paths:
        with path.open("r", encoding="utf-8") as stream:
            for line_number, line in enumerate(stream, 1):
                if not line.strip():
                    continue
                try:
                    value = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise ValueError(f"{path}:{line_number}: {exc}") from exc
                if value.get("manualOrder"):
                    yield value


def sample(record: dict[str, Any]) -> dict[str, Any]:
    order = dict(record["manualOrder"])
    observation = order.pop("stateBefore", None) or record.get("observation") or {}
    if order.get("abilityName") in NO_TARGET_ITEMS and order.get("source") in {
        "keyboard_then_left_click", "keyboard_item"
    }:
        order["order"] = 8
        order.pop("position", None)
        order.pop("targetIndex", None)
        order.pop("targetName", None)
    raw_order = order.get("order")
    order["orderName"] = ORDER_NAMES.get(raw_order, f"ORDER_{raw_order}")
    return {
        "recordedAt": record.get("recordedAt"),
        "observation": observation,
        "label": order,
    }


def is_duplicate(left: dict[str, Any], right: dict[str, Any]) -> bool:
    a, b = left["label"], right["label"]
    try:
        delta = abs(float(a.get("gameTime")) - float(b.get("gameTime")))
    except (TypeError, ValueError):
        return False
    if a.get("order") == 16 and b.get("order") == 16:
        return delta <= 1.0 and "prepare_unit_orders" in {a.get("source"), b.get("source")}
    if (
        a.get("order") == b.get("order")
        and a.get("order") in TARGET_CLICK_ORDERS
        and a.get("targetIndex") is not None
        and a.get("targetIndex") == b.get("targetIndex")
        and a.get("source") in RIGHT_CLICK_SOURCES
        and b.get("source") in RIGHT_CLICK_SOURCES
        and delta <= 0.45
    ):
        # Windows/Dota auto-repeat can report one held RMB as many fresh clicks.
        # It is one sustained target decision, not dozens of independent labels.
        return True
    return (
        a.get("order") in CAST_ORDERS
        and b.get("order") in CAST_ORDERS
        and a.get("abilityName")
        and a.get("abilityName") == b.get("abilityName")
        and delta <= 0.75
    )


def deduplicate(values: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for value in values:
        duplicate_index = next(
            (i for i in range(max(0, len(result) - 12), len(result)) if is_duplicate(result[i], value)),
            None,
        )
        if duplicate_index is None:
            result.append(value)
            continue
        old_source = result[duplicate_index]["label"].get("source")
        new_source = value["label"].get("source")
        # Exact callback data wins for casts; observed state wins for purchases
        # because it contains the purchased item name.
        if new_source == "prepare_unit_orders" and value["label"].get("order") != 16:
            result[duplicate_index] = value
        elif new_source == "observed_purchase" or old_source not in {
            "prepare_unit_orders", "observed_purchase"
        }:
            result[duplicate_index] = value
    return result


def is_validation(value: dict[str, Any], fraction: float) -> bool:
    key = str(value.get("recordedAt", "")) + ":" + str(value.get("label", {}).get("sequence", ""))
    bucket = int(hashlib.sha256(key.encode()).hexdigest()[:8], 16) / 0xFFFFFFFF
    return bucket < fraction


def main() -> None:
    parser = argparse.ArgumentParser(description="Extract supervised micro samples from bridge recordings")
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--output-dir", type=Path, default=Path("dataset"))
    parser.add_argument("--validation-fraction", type=float, default=0.1)
    args = parser.parse_args()
    if not 0 <= args.validation_fraction < 1:
        raise SystemExit("--validation-fraction must be in [0, 1)")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    train_path = args.output_dir / "train.jsonl"
    validation_path = args.output_dir / "validation.jsonl"
    train_count = validation_count = 0
    with train_path.open("w", encoding="utf-8") as train, validation_path.open("w", encoding="utf-8") as validation:
        values = deduplicate(sample(record) for record in records(args.inputs))
        for value in values:
            stream = validation if is_validation(value, args.validation_fraction) else train
            stream.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
            if stream is validation:
                validation_count += 1
            else:
                train_count += 1
    print(f"train={train_count} validation={validation_count}")
    print(train_path.resolve())
    print(validation_path.resolve())


if __name__ == "__main__":
    main()
