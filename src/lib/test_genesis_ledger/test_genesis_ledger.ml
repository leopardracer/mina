include Genesis_ledger.Make (struct
  include (val Genesis_ledger.fetch_ledger_exn "test")

  let directory = `Ephemeral

  let depth = Genesis_constants.Compiled.Constraint_constants.t.ledger_depth
end)
