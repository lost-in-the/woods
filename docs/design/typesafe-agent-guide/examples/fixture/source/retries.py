# Synthetic distractor: deterministic retry timing, unrelated to the catalog task.
def retry_delay(attempt):
    return min(2 ** attempt, 30)
