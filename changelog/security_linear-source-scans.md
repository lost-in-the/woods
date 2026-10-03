- Keep template and dependency scans linear on adversarial source. The ERB
  form-action scan, the shared scanner's form-action, service, mailer, and job
  reference patterns, and the new HAML and jbuilder scans could backtrack
  polynomially; on Ruby 3.0 a crafted 50k-character file stalled extraction for
  seconds per pattern. Results are unchanged.
