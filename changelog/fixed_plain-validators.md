- Validator extraction admits every class a file under `app/validators/` is
  named for, so plain validator objects (an arg-less `validate`, `valid?`, or
  delegated `errors`) become `validator` units with
  `metadata[:validator_type] = :plain`. ActiveModel validators are unchanged.
  Models that construct these validators now gain `validator` edges.
