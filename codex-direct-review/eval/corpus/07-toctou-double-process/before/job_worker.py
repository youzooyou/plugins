processed = set()


def process_job(job_id, work_fn):
    """Process a job exactly once, even if called concurrently from multiple threads."""
    if job_id not in processed:
        result = work_fn(job_id)
        processed.add(job_id)
        return result
    return None
