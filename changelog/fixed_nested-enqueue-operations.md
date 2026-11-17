- A flow now lists an enqueue anywhere in an expression a call evaluates as an async operation.
  Keyword arguments, arrays, hashes, parentheses, splats, ternaries, `||` and interpolation all count.
  An enqueue in a receiver chain counts too, as in `render json: { id: ReportJob.perform_later.job_id }`.
  Before, only an enqueue passed directly as a positional argument, or nested in another call there, was listed.
  An enqueue inside a lambda or proc argument, or a `defined?` operand, is still not listed: it does not run there.
  Run a full extraction to refresh precomputed flows and callback `operations`.
