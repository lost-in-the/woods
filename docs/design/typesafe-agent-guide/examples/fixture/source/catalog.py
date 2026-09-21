# Synthetic example source. It is read as evidence, never executed by the ranker.
def visible_items(items):
    return [item for item in items if item.get("published", False)]


def display_title(item):
    return item["title"].strip()
