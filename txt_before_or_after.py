def _summarize_request_text_around_images(
    prompt_length: int,
    images_in_request_layout: list[list[int]],
) -> dict[str, int | bool]:
    """Summarize the text prefix/suffix around all images in one request.

    Every item in ``images_in_request_layout`` is ``[start, length]`` in the
    original prompt's request-local layout. Text between multiple images is
    deliberately excluded; only tokens before the first image and after the
    last image are counted.
    """
    prompt_length = int(prompt_length)
    if prompt_length < 0:
        raise ValueError(
            f"prompt length must be non-negative, got {prompt_length}"
        )

    image_intervals = []
    for image_start_len in images_in_request_layout:
        image_start, image_length = (int(value) for value in image_start_len)
        if image_length <= 0:
            continue

        # Keep this helper portable by clipping malformed or boundary-crossing
        # image intervals to the original prompt.
        clipped_image_start = max(0, image_start)
        clipped_image_end = min(prompt_length, image_start + image_length)
        if clipped_image_start < clipped_image_end:
            image_intervals.append((clipped_image_start, clipped_image_end))

    if not image_intervals:
        return {
            "has_images": False,
            "image_count": 0,
            "has_text_before_all_images": False,
            "text_before_all_images_length": 0,
            "has_text_after_all_images": False,
            "text_after_all_images_length": 0,
        }

    first_image_start = min(start for start, _ in image_intervals)
    last_image_end = max(end for _, end in image_intervals)
    text_before_all_images_length = first_image_start
    text_after_all_images_length = prompt_length - last_image_end

    return {
        "has_images": True,
        "image_count": len(image_intervals),
        "has_text_before_all_images": text_before_all_images_length > 0,
        "text_before_all_images_length": text_before_all_images_length,
        "has_text_after_all_images": text_after_all_images_length > 0,
        "text_after_all_images_length": text_after_all_images_length,
    }


def _log_request_text_around_images(
    req_id: str,
    prompt_length: int,
    images_in_request_layout: list[list[int]],
) -> dict[str, int | bool]:
    """Log and return the image-surrounding text summary for one request."""
    summary = _summarize_request_text_around_images(
        prompt_length,
        images_in_request_layout,
    )
    logger.info(
        "[token-pruning][image-layout] scope=full_prompt, req_id=%s, "
        "prompt_length=%d, has_images=%s, image_count=%d, "
        "has_text_before_all_images=%s, "
        "text_before_all_images_length=%d, "
        "has_text_after_all_images=%s, text_after_all_images_length=%d",
        req_id,
        prompt_length,
        summary["has_images"],
        summary["image_count"],
        summary["has_text_before_all_images"],
        summary["text_before_all_images_length"],
        summary["has_text_after_all_images"],
        summary["text_after_all_images_length"],
    )
    return summary