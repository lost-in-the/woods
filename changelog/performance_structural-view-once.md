- The dependency graph keeps its structural view (the graph without documentation units) until its structure changes.
  Writing the graph and analysing it each built their own view, so an application that indexes documents
  ranked the graph twice and serialized the view from scratch in every run that writes the graph.
  On a 10,389-node graph the write-then-analyse sequence goes from about 2.6 s to 2.1 s, with identical output.
