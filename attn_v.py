def _attn_with_v_score_computer(
    attn_metadata,
    query: torch.Tensor,
    key_cache: torch.Tensor,
    value_cache: torch.Tensor,
    allow_text_to_image_non_causal_attention: bool = False,
    text_only: bool = False,
) -> torch.Tensor:
    """Weight received-attention probabilities by per-head Value norms.

    By default, causal attention is preserved and every valid Query in the
    current chunk participates in aggregation. The returned score follows the
    packed current-sequence layout with shape ``(num_tokens, 1)``; non-image
    token scores are zero.
    """
    if value_cache is None:
        raise ValueError(
            "value_cache is required by the attn_with_v strategy"
        )

    forward_context = get_forward_context()
    llm_pruning_infos = forward_context.additional_kwargs["llm_pruning_infos"]
    txt_indices = llm_pruning_infos["txt_indices"]
    querys = llm_pruning_infos["querys"]
    images = llm_pruning_infos["images"]

    max_model_len = txt_indices.shape[1]
    num_tokens = attn_metadata.actual_seq_lengths_q[-1]
    num_requests = txt_indices.shape[0]
    query_lengths = querys[:, 1]  # (Q,)
    query_start = querys[:, 0]  # (Q,)

    # =====================================================================
    # a. Extract Q/K/V
    # K and V share the complete request-local paged-cache layout.
    # =====================================================================
    indices = torch.arange(
        max_model_len, device=query.device
    ).unsqueeze(0).expand(num_requests, -1)  # (Q, max_model_len)
    key_lengths = attn_metadata.seq_lens.to(device=query.device)  # (Q,)
    valid_mask_in_k_layout = (
        indices < key_lengths.unsqueeze(-1)
    )  # (Q, max_model_len)
    valid_indices_in_k_layout = indices.masked_fill(
        ~valid_mask_in_k_layout, 0
    )

    k = _extract_key_from_k_cache(
        attn_metadata,
        num_requests,
        key_cache,
        valid_indices_in_k_layout,
    )  # (Q, max_model_len, num_head_key, head_dim)
    k.masked_fill_(
        ~valid_mask_in_k_layout.unsqueeze(-1).unsqueeze(-1), 0.0
    )

    v = _extract_value_from_v_cache(
        attn_metadata,
        num_requests,
        value_cache,
        valid_indices_in_k_layout,
    )  # (Q, max_model_len, num_head_value, head_dim)
    v.masked_fill_(
        ~valid_mask_in_k_layout.unsqueeze(-1).unsqueeze(-1), 0.0
    )

    valid_mask_in_q_layout = (
        indices < query_lengths.unsqueeze(-1)
    )  # (Q, max_model_len)
    packed_query_indices = query_start.unsqueeze(-1) + indices
    packed_query_indices = packed_query_indices.masked_fill(
        ~valid_mask_in_q_layout, 0
    )
    q = query[packed_query_indices]
    q.masked_fill_(
        ~valid_mask_in_q_layout.unsqueeze(-1).unsqueeze(-1), 0.0
    )  # (Q, max_model_len, num_head_q, head_dim)

    # =====================================================================
    # b. Build text/image masks in Query/Key layouts.
    # =====================================================================
    history_len = key_lengths - query_lengths  # (Q,)
    (
        image_mask_in_q_layout,
        text_mask_in_q_layout,
        image_mask_in_k_layout,
        text_mask_in_k_layout,
    ) = _mask_factory(
        packed_query_indices=packed_query_indices,
        valid_mask_in_q_layout=valid_mask_in_q_layout,
        images=images,
        history_len=history_len,
        query_lengths=query_lengths,
        key_lengths=key_lengths,
    )

    # =====================================================================
    # c. Reconstruct per-Q-head attention probabilities.
    # =====================================================================
    attn_score, valid_attn_mask_in_qk_layout = _compute_attn_score(
        q,
        k,
        history_len,
        valid_mask_in_q_layout=valid_mask_in_q_layout,
        valid_mask_in_k_layout=valid_mask_in_k_layout,
        text_mask_in_q_layout=text_mask_in_q_layout,
        image_mask_in_k_layout=image_mask_in_k_layout,
        allow_text_to_image_non_causal_attention=(
            allow_text_to_image_non_causal_attention
        ),
    )  # (Q, max_model_len, max_model_len, num_head_q)

    # =====================================================================
    # d. Convert attention probability into Value contribution magnitude.
    # For one Query/Key/head edge, ||A_ij * V_j||_2 = A_ij * ||V_j||_2.
    # =====================================================================
    num_head_q = attn_score.shape[-1]
    num_head_value = v.shape[2]
    if num_head_q % num_head_value != 0:
        raise ValueError(
            "num_head_q must be divisible by num_head_value"
        )
    num_q_heads_per_value_head = num_head_q // num_head_value

    v_norm_in_k_layout = torch.linalg.vector_norm(
        v.float(),
        ord=2,
        dim=-1,
    )  # (Q, max_model_len, num_head_value)
    v_norm_in_k_layout = v_norm_in_k_layout.repeat_interleave(
        num_q_heads_per_value_head,
        dim=-1,
    )  # (Q, max_model_len, num_head_q)

    if text_only:
        selected_attn_mask_in_qk_layout = text_mask_in_q_layout[:, :, None]
    else:
        selected_attn_mask_in_qk_layout = valid_mask_in_q_layout[:, :, None]

    received_value_contribution = _aggregate_selected_along_tokens(
        attn_score=attn_score,
        valid_attn_mask_in_qk_layout=valid_attn_mask_in_qk_layout,
        selected_attn_mask_in_qk_layout=selected_attn_mask_in_qk_layout,
        use_inplace_mask_fill=True,
    )  # (Q, max_model_len, num_head_q)
    # V_j is independent of the Query axis, so multiplying after Query
    # aggregation is equivalent to aggregating A_ij * ||V_j|| and avoids
    # materializing another full (Q, Lq, Lk, Hq) tensor.
    received_value_contribution.mul_(v_norm_in_k_layout)
    received_value_contribution = received_value_contribution.mean(dim=-1)
    # (Q, max_model_len), mean over Q-heads

    # =====================================================================
    # e. Extract image-token contributions and return the standard layout.
    # =====================================================================
    score_per_image = _extract_per_image_scores(
        received_value_contribution,
        querys,
        images,
        history_len,
    )  # (P, max_model_len)
    eps = 1e-10
    score_per_image = score_per_image / (
        score_per_image.sum(dim=-1, keepdim=True) + eps
    )

    image_start_in_sequence = images[:, 0]  # (P,)
    image_lengths = images[:, 1]  # (P,)
    image_end_in_sequence = image_start_in_sequence + image_lengths
    score = _per_image_to_whole_sequence(
        score_per_image,
        image_start_in_sequence,
        image_end_in_sequence - 1,
        num_tokens,
    ).unsqueeze(-1)  # (num_tokens, 1)

    strategy_name = "attn_with_v"
    if allow_text_to_image_non_causal_attention:
        strategy_name += "_nc"
    if text_only:
        strategy_name += "_txt"
    logger.info(
        "tyclog: score compute success, strategy=%s, causal=%s, "
        "txt_only=%s",
        strategy_name,
        not allow_text_to_image_non_causal_attention,
        text_only,
    )
    return score