# Data Flow

```mermaid
flowchart TD
  Woods(["new"])
  Set["Set"]
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods__Ast(["new"])
  Woods__Ast -->|construction: new| Set
  Woods__Ast -->|construction: new| Set
  Woods__Ast__CallSiteExtractor(["new"])
  Woods__Ast__CallSiteExtractor -->|construction: new| Set
  Woods__Ast__CallSiteExtractor_extract_significant(["new"])
  Woods__Ast__CallSiteExtractor_extract_significant -->|construction: new| Set
  Parser["Parser"]
  Woods -->|construction: new| Parser
  _parser["@parser"]
  Woods -->|deserialization: parse| _parser
  Woods -->|deserialization: parse| _parser
  Woods__Ast -->|construction: new| Parser
  Woods__Ast -->|deserialization: parse| _parser
  Woods__Ast -->|deserialization: parse| _parser
  Woods__Ast__MethodExtractor(["new"])
  Woods__Ast__MethodExtractor -->|construction: new| Parser
  Woods__Ast__MethodExtractor -->|deserialization: parse| _parser
  Woods__Ast__MethodExtractor -->|deserialization: parse| _parser
  Woods__Ast__MethodExtractor_initialize(["new"])
  Woods__Ast__MethodExtractor_initialize -->|construction: new| Parser
  Woods__Ast__MethodExtractor_extract_method[\"deserialization"\]
  Woods__Ast__MethodExtractor_extract_method -->|deserialization: parse| _parser
  Woods__Ast__MethodExtractor_extract_all_methods[\"deserialization"\]
  Woods__Ast__MethodExtractor_extract_all_methods -->|deserialization: parse| _parser
  Struct["Struct"]
  Woods -->|construction: new| Struct
  Woods__Ast -->|construction: new| Struct
  Prism["Prism"]
  Woods -->|deserialization: parse| Prism
  Parser__Source__Buffer["Parser::Source::Buffer"]
  Woods -->|construction: new| Parser__Source__Buffer
  Parser__CurrentRuby["Parser::CurrentRuby"]
  Woods -->|deserialization: parse| Parser__CurrentRuby
  Node["Node"]
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods -->|construction: new| Node
  Woods__Ast -->|deserialization: parse| Prism
  Woods__Ast -->|construction: new| Parser__Source__Buffer
  Woods__Ast -->|deserialization: parse| Parser__CurrentRuby
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast -->|construction: new| Node
  Woods__Ast__Parser(["parse"])
  Woods__Ast__Parser -->|deserialization: parse| Prism
  Woods__Ast__Parser -->|construction: new| Parser__Source__Buffer
  Woods__Ast__Parser -->|deserialization: parse| Parser__CurrentRuby
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser -->|construction: new| Node
  Woods__Ast__Parser_parse_with_prism[\"deserialization"\]
  Woods__Ast__Parser_parse_with_prism -->|deserialization: parse| Prism
  Woods__Ast__Parser_parse_with_parser_gem(["new"])
  Woods__Ast__Parser_parse_with_parser_gem -->|construction: new| Parser__Source__Buffer
  Woods__Ast__Parser_parse_with_parser_gem -->|deserialization: parse| Parser__CurrentRuby
  Woods__Ast__Parser_convert_prism_node(["new"])
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_node -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_class(["new"])
  Woods__Ast__Parser_convert_prism_class -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_module(["new"])
  Woods__Ast__Parser_convert_prism_module -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_def(["new"])
  Woods__Ast__Parser_convert_prism_def -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_call(["new"])
  Woods__Ast__Parser_convert_prism_call -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_call -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_call -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_constant_path(["new"])
  Woods__Ast__Parser_convert_prism_constant_path -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_if(["new"])
  Woods__Ast__Parser_convert_prism_if -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_if -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_unless(["new"])
  Woods__Ast__Parser_convert_prism_unless -->|construction: new| Node
  Woods__Ast__Parser_convert_prism_case(["new"])
  Woods__Ast__Parser_convert_prism_case -->|construction: new| Node
  Woods__Ast__Parser_convert_parser_node(["new"])
  Woods__Ast__Parser_convert_parser_node -->|construction: new| Node
  Woods__Ast__Parser_convert_parser_node -->|construction: new| Node
  Woods__Ast__Parser_convert_parser_node -->|construction: new| Node
  Woods__Ast__Parser_convert_parser_node -->|construction: new| Node
  Woods__Ast__Parser_convert_parser_node -->|construction: new| Node
  Woods__Ast__Parser_convert_parser_node -->|construction: new| Node
  Woods__Ast__Parser_convert_parser_node -->|construction: new| Node
  Woods__Ast__Parser_convert_parser_node -->|construction: new| Node
  Woods__Ast__Parser_convert_parser_node -->|construction: new| Node
  Woods__Ast__Parser_convert_parser_node -->|construction: new| Node
  Woods__Ast__Parser_convert_parser_node -->|construction: new| Node
  Woods__Ast__Parser_convert_parser_node -->|construction: new| Node
  Woods__Ast__Parser_convert_parser_node -->|construction: new| Node
  Woods__Ast__Parser_convert_parser_node -->|construction: new| Node
  Configuration["Configuration"]
  Woods -->|construction: new| Configuration
  Retriever["Retriever"]
  Woods -->|construction: new| Retriever
  Storage__VectorStore__InMemory["Storage::VectorStore::InMemory"]
  Woods -->|construction: new| Storage__VectorStore__InMemory
  Storage__VectorStore__Pgvector["Storage::VectorStore::Pgvector"]
  Woods -->|construction: new| Storage__VectorStore__Pgvector
  Storage__VectorStore__Qdrant["Storage::VectorStore::Qdrant"]
  Woods -->|construction: new| Storage__VectorStore__Qdrant
  Embedding__Provider__OpenAI["Embedding::Provider::OpenAI"]
  Woods -->|construction: new| Embedding__Provider__OpenAI
  Embedding__Provider__Ollama["Embedding::Provider::Ollama"]
  Woods -->|construction: new| Embedding__Provider__Ollama
  Storage__MetadataStore__InMemory["Storage::MetadataStore::InMemory"]
  Woods -->|construction: new| Storage__MetadataStore__InMemory
  Storage__MetadataStore__SQLite["Storage::MetadataStore::SQLite"]
  Woods -->|construction: new| Storage__MetadataStore__SQLite
  Storage__GraphStore__Memory["Storage::GraphStore::Memory"]
  Woods -->|construction: new| Storage__GraphStore__Memory
  Woods__Builder(["new"])
  Woods__Builder -->|construction: new| Configuration
  Woods__Builder -->|construction: new| Retriever
  Woods__Builder -->|construction: new| Storage__VectorStore__InMemory
  Woods__Builder -->|construction: new| Storage__VectorStore__Pgvector
  Woods__Builder -->|construction: new| Storage__VectorStore__Qdrant
  Woods__Builder -->|construction: new| Embedding__Provider__OpenAI
  Woods__Builder -->|construction: new| Embedding__Provider__Ollama
  Woods__Builder -->|construction: new| Storage__MetadataStore__InMemory
  Woods__Builder -->|construction: new| Storage__MetadataStore__SQLite
  Woods__Builder -->|construction: new| Storage__GraphStore__Memory
  Woods__Builder_preset_config(["new"])
  Woods__Builder_preset_config -->|construction: new| Configuration
  Woods__Builder_build_retriever(["new"])
  Woods__Builder_build_retriever -->|construction: new| Retriever
  Woods__Builder_build_vector_store(["new"])
  Woods__Builder_build_vector_store -->|construction: new| Storage__VectorStore__InMemory
  Woods__Builder_build_vector_store -->|construction: new| Storage__VectorStore__Pgvector
  Woods__Builder_build_vector_store -->|construction: new| Storage__VectorStore__Qdrant
  Woods__Builder_build_embedding_provider(["new"])
  Woods__Builder_build_embedding_provider -->|construction: new| Embedding__Provider__OpenAI
  Woods__Builder_build_embedding_provider -->|construction: new| Embedding__Provider__Ollama
  Woods__Builder_build_metadata_store(["new"])
  Woods__Builder_build_metadata_store -->|construction: new| Storage__MetadataStore__InMemory
  Woods__Builder_build_metadata_store -->|construction: new| Storage__MetadataStore__SQLite
  Woods__Builder_build_graph_store(["new"])
  Woods__Builder_build_graph_store -->|construction: new| Storage__GraphStore__Memory
  ModelChunker["ModelChunker"]
  Woods -->|construction: new| ModelChunker
  ControllerChunker["ControllerChunker"]
  Woods -->|construction: new| ControllerChunker
  Chunk["Chunk"]
  Woods -->|construction: new| Chunk
  Woods -->|construction: new| Chunk
  Woods -->|construction: new| Chunk
  Woods__Chunking(["new"])
  Woods__Chunking -->|construction: new| ModelChunker
  Woods__Chunking -->|construction: new| ControllerChunker
  Woods__Chunking -->|construction: new| Chunk
  Woods__Chunking -->|construction: new| Chunk
  Woods__Chunking -->|construction: new| Chunk
  Woods__Chunking__SemanticChunker(["new"])
  Woods__Chunking__SemanticChunker -->|construction: new| ModelChunker
  Woods__Chunking__SemanticChunker -->|construction: new| ControllerChunker
  Woods__Chunking__SemanticChunker -->|construction: new| Chunk
  Woods__Chunking__ModelChunker(["new"])
  Woods__Chunking__ModelChunker -->|construction: new| Chunk
  Woods__Chunking__ControllerChunker(["new"])
  Woods__Chunking__ControllerChunker -->|construction: new| Chunk
  Woods__Chunking__SemanticChunker_chunk(["new"])
  Woods__Chunking__SemanticChunker_chunk -->|construction: new| ModelChunker
  Woods__Chunking__SemanticChunker_chunk -->|construction: new| ControllerChunker
  Woods__Chunking__SemanticChunker_build_whole_chunk(["new"])
  Woods__Chunking__SemanticChunker_build_whole_chunk -->|construction: new| Chunk
  Woods__Chunking__ModelChunker_build_chunk(["new"])
  Woods__Chunking__ModelChunker_build_chunk -->|construction: new| Chunk
  Woods__Chunking__ControllerChunker_build_chunk(["new"])
  Woods__Chunking__ControllerChunker_build_chunk -->|construction: new| Chunk
  JSON["JSON"]
  Woods -->|deserialization: parse| JSON
  Woods__Console[\"deserialization"\]
  Woods__Console -->|deserialization: parse| JSON
  Woods__Console__AuditLogger[\"deserialization"\]
  Woods__Console__AuditLogger -->|deserialization: parse| JSON
  Woods__Console__AuditLogger_entries[\"deserialization"\]
  Woods__Console__AuditLogger_entries -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods__Console -->|deserialization: parse| JSON
  Woods__Console__Bridge[\"deserialization"\]
  Woods__Console__Bridge -->|deserialization: parse| JSON
  Woods__Console__Bridge_parse_request[\"deserialization"\]
  Woods__Console__Bridge_parse_request -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods__Console -->|deserialization: parse| JSON
  Woods__Console__ConnectionManager[\"deserialization"\]
  Woods__Console__ConnectionManager -->|deserialization: parse| JSON
  Woods__Console__ConnectionManager_send_request[\"deserialization"\]
  Woods__Console__ConnectionManager_send_request -->|deserialization: parse| JSON
  ConnectionManager["ConnectionManager"]
  Woods -->|construction: new| ConnectionManager
  SafeContext["SafeContext"]
  Woods -->|construction: new| SafeContext
  MCP__Server["MCP::Server"]
  Woods -->|construction: new| MCP__Server
  MCP__Tool__Response["MCP::Tool::Response"]
  Woods -->|construction: new| MCP__Tool__Response
  Woods -->|construction: new| MCP__Tool__Response
  Woods -->|construction: new| MCP__Tool__Response
  SqlValidator["SqlValidator"]
  Woods -->|construction: new| SqlValidator
  Woods__Console -->|construction: new| ConnectionManager
  Woods__Console -->|construction: new| SafeContext
  Woods__Console -->|construction: new| MCP__Server
  Woods__Console -->|construction: new| MCP__Tool__Response
  Woods__Console -->|construction: new| MCP__Tool__Response
  Woods__Console -->|construction: new| MCP__Tool__Response
  Woods__Console -->|construction: new| SqlValidator
  Woods__Console__Server(["new"])
  Woods__Console__Server -->|construction: new| ConnectionManager
  Woods__Console__Server -->|construction: new| SafeContext
  Woods__Console__Server -->|construction: new| MCP__Server
  Woods__Console__Server -->|construction: new| MCP__Tool__Response
  Woods__Console__Server -->|construction: new| MCP__Tool__Response
  Woods__Console__Server -->|construction: new| MCP__Tool__Response
  Woods__Console__Server -->|construction: new| SqlValidator
  EmbeddingCost["EmbeddingCost"]
  Woods -->|construction: new| EmbeddingCost
  StorageCost["StorageCost"]
  Woods -->|construction: new| StorageCost
  Woods__CostModel(["new"])
  Woods__CostModel -->|construction: new| EmbeddingCost
  Woods__CostModel -->|construction: new| StorageCost
  Woods__CostModel__Estimator(["new"])
  Woods__CostModel__Estimator -->|construction: new| EmbeddingCost
  Woods__CostModel__Estimator -->|construction: new| StorageCost
  Woods__CostModel__Estimator_initialize(["new"])
  Woods__CostModel__Estimator_initialize -->|construction: new| EmbeddingCost
  Woods__CostModel__Estimator_initialize -->|construction: new| StorageCost
  SchemaVersion["SchemaVersion"]
  Woods -->|construction: new| SchemaVersion
  Woods__Db(["new"])
  Woods__Db -->|construction: new| SchemaVersion
  Woods__Db__Migrator(["new"])
  Woods__Db__Migrator -->|construction: new| SchemaVersion
  Woods__Db__Migrator_initialize(["new"])
  Woods__Db__Migrator_initialize -->|construction: new| SchemaVersion
  Woods -->|construction: new| Set
  affected["affected"]
  Woods -->|serialization: to_a| affected
  Woods__DependencyGraph(["new"])
  Woods__DependencyGraph -->|construction: new| Set
  Woods__DependencyGraph -->|serialization: to_a| affected
  Woods__DependencyGraph_affected_by(["new"])
  Woods__DependencyGraph_affected_by -->|construction: new| Set
  Woods__DependencyGraph_affected_by -->|serialization: to_a| affected
  Woods__DependencyGraph_from_h(["new"])
  Woods -->|deserialization: parse| JSON
  ExtractedUnit["ExtractedUnit"]
  Woods -->|construction: new| ExtractedUnit
  Woods -->|deserialization: parse| JSON
  Woods__Embedding(["parse"])
  Woods__Embedding -->|deserialization: parse| JSON
  Woods__Embedding -->|construction: new| ExtractedUnit
  Woods__Embedding -->|deserialization: parse| JSON
  Woods__Embedding__Indexer(["parse"])
  Woods__Embedding__Indexer -->|deserialization: parse| JSON
  Woods__Embedding__Indexer -->|construction: new| ExtractedUnit
  Woods__Embedding__Indexer -->|deserialization: parse| JSON
  Woods__Embedding__Indexer_load_units[\"deserialization"\]
  Woods__Embedding__Indexer_load_units -->|deserialization: parse| JSON
  Woods__Embedding__Indexer_build_unit(["new"])
  Woods__Embedding__Indexer_build_unit -->|construction: new| ExtractedUnit
  Woods__Embedding__Indexer_load_checkpoint[\"deserialization"\]
  Woods__Embedding__Indexer_load_checkpoint -->|deserialization: parse| JSON
  Net__HTTP["Net::HTTP"]
  Woods -->|construction: new| Net__HTTP
  Net__HTTP__Post["Net::HTTP::Post"]
  Woods -->|construction: new| Net__HTTP__Post
  Woods -->|deserialization: parse| JSON
  Woods__Embedding -->|construction: new| Net__HTTP
  Woods__Embedding -->|construction: new| Net__HTTP__Post
  Woods__Embedding -->|deserialization: parse| JSON
  Woods__Embedding__Provider(["new"])
  Woods__Embedding__Provider -->|construction: new| Net__HTTP
  Woods__Embedding__Provider -->|construction: new| Net__HTTP__Post
  Woods__Embedding__Provider -->|deserialization: parse| JSON
  Woods__Embedding__Provider__OpenAI(["new"])
  Woods__Embedding__Provider__OpenAI -->|construction: new| Net__HTTP
  Woods__Embedding__Provider__OpenAI -->|construction: new| Net__HTTP__Post
  Woods__Embedding__Provider__OpenAI -->|deserialization: parse| JSON
  Woods__Embedding__Provider__OpenAI_post_request(["new"])
  Woods__Embedding__Provider__OpenAI_post_request -->|construction: new| Net__HTTP
  Woods__Embedding__Provider__OpenAI_post_request -->|construction: new| Net__HTTP__Post
  Woods__Embedding__Provider__OpenAI_post_request -->|deserialization: parse| JSON
  Woods -->|construction: new| Net__HTTP
  Woods -->|construction: new| Net__HTTP__Post
  Woods -->|deserialization: parse| JSON
  Woods__Embedding -->|construction: new| Net__HTTP
  Woods__Embedding -->|construction: new| Net__HTTP__Post
  Woods__Embedding -->|deserialization: parse| JSON
  Woods__Embedding__Provider -->|construction: new| Net__HTTP
  Woods__Embedding__Provider -->|construction: new| Net__HTTP__Post
  Woods__Embedding__Provider -->|deserialization: parse| JSON
  Woods__Embedding__Provider__Ollama(["new"])
  Woods__Embedding__Provider__Ollama -->|construction: new| Net__HTTP
  Woods__Embedding__Provider__Ollama -->|construction: new| Net__HTTP__Post
  Woods__Embedding__Provider__Ollama -->|deserialization: parse| JSON
  Woods__Embedding__Provider__Ollama_post_request(["new"])
  Woods__Embedding__Provider__Ollama_post_request -->|construction: new| Net__HTTP
  Woods__Embedding__Provider__Ollama_post_request -->|construction: new| Net__HTTP__Post
  Woods__Embedding__Provider__Ollama_post_request -->|deserialization: parse| JSON
  Woods -->|construction: new| Struct
  Woods -->|construction: new| Struct
  EvaluationReport["EvaluationReport"]
  Woods -->|construction: new| EvaluationReport
  QueryResult["QueryResult"]
  Woods -->|construction: new| QueryResult
  Woods__Evaluation(["new"])
  Woods__Evaluation -->|construction: new| Struct
  Woods__Evaluation -->|construction: new| Struct
  Woods__Evaluation -->|construction: new| EvaluationReport
  Woods__Evaluation -->|construction: new| QueryResult
  Woods__Evaluation__Evaluator(["new"])
  Woods__Evaluation__Evaluator -->|construction: new| Struct
  Woods__Evaluation__Evaluator -->|construction: new| Struct
  Woods__Evaluation__Evaluator -->|construction: new| EvaluationReport
  Woods__Evaluation__Evaluator -->|construction: new| QueryResult
  Woods__Evaluation__Evaluator_evaluate(["new"])
  Woods__Evaluation__Evaluator_evaluate -->|construction: new| EvaluationReport
  Woods__Evaluation__Evaluator_evaluate_query(["new"])
  Woods__Evaluation__Evaluator_evaluate_query -->|construction: new| QueryResult
  Woods -->|construction: new| Struct
  Woods -->|deserialization: parse| JSON
  Query["Query"]
  Woods -->|construction: new| Query
  Woods__Evaluation -->|construction: new| Struct
  Woods__Evaluation -->|deserialization: parse| JSON
  Woods__Evaluation -->|construction: new| Query
  Woods__Evaluation__QuerySet(["new"])
  Woods__Evaluation__QuerySet -->|construction: new| Struct
  Woods__Evaluation__QuerySet -->|deserialization: parse| JSON
  Woods__Evaluation__QuerySet -->|construction: new| Query
  Woods__Evaluation__QuerySet_load(["parse"])
  Woods__Evaluation__QuerySet_load -->|deserialization: parse| JSON
  Woods__Evaluation__QuerySet_parse_query(["new"])
  Woods__Evaluation__QuerySet_parse_query -->|construction: new| Query
  metadata["metadata"]
  Woods -->|serialization: to_json| metadata
  Woods__ExtractedUnit[/"serialization"/]
  Woods__ExtractedUnit -->|serialization: to_json| metadata
  Woods__ExtractedUnit_estimated_tokens[/"serialization"/]
  Woods__ExtractedUnit_estimated_tokens -->|serialization: to_json| metadata
  Pathname["Pathname"]
  Woods -->|construction: new| Pathname
  DependencyGraph["DependencyGraph"]
  Woods -->|construction: new| DependencyGraph
  GraphAnalyzer["GraphAnalyzer"]
  Woods -->|construction: new| GraphAnalyzer
  Woods -->|construction: new| Pathname
  Woods -->|construction: new| Set
  extractor_class["extractor_class"]
  Woods -->|construction: new| extractor_class
  Mutex["Mutex"]
  Woods -->|construction: new| Mutex
  Thread["Thread"]
  Woods -->|construction: new| Thread
  Woods -->|construction: new| extractor_class
  FlowPrecomputer["FlowPrecomputer"]
  Woods -->|construction: new| FlowPrecomputer
  Hash["Hash"]
  Woods -->|construction: new| Hash
  _dependency_graph["@dependency_graph"]
  Woods -->|serialization: to_h| _dependency_graph
  Woods -->|serialization: to_h| _dependency_graph
  Woods -->|deserialization: parse| JSON
  Woods -->|serialization: to_h| _dependency_graph
  EXTRACTORS___["EXTRACTORS.[]"]
  Woods -->|construction: new| EXTRACTORS___
  Woods__Extractor(["new"])
  Woods__Extractor -->|construction: new| Pathname
  Woods__Extractor -->|construction: new| DependencyGraph
  Woods__Extractor -->|construction: new| GraphAnalyzer
  Woods__Extractor -->|construction: new| Pathname
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| extractor_class
  Woods__Extractor -->|construction: new| Mutex
  Woods__Extractor -->|construction: new| Thread
  Woods__Extractor -->|construction: new| extractor_class
  Woods__Extractor -->|construction: new| FlowPrecomputer
  Woods__Extractor -->|construction: new| Hash
  Woods__Extractor -->|serialization: to_h| _dependency_graph
  Woods__Extractor -->|serialization: to_h| _dependency_graph
  Woods__Extractor -->|deserialization: parse| JSON
  Woods__Extractor -->|serialization: to_h| _dependency_graph
  Woods__Extractor -->|construction: new| EXTRACTORS___
  Woods__Extractor_initialize(["new"])
  Woods__Extractor_initialize -->|construction: new| Pathname
  Woods__Extractor_initialize -->|construction: new| DependencyGraph
  Woods__Extractor_extract_all(["new"])
  Woods__Extractor_extract_all -->|construction: new| GraphAnalyzer
  Woods__Extractor_extract_changed(["new"])
  Woods__Extractor_extract_changed -->|construction: new| Pathname
  Woods__Extractor_extract_changed -->|construction: new| Set
  Woods__Extractor_extract_all_sequential(["new"])
  Woods__Extractor_extract_all_sequential -->|construction: new| extractor_class
  Woods__Extractor_extract_all_concurrent(["new"])
  Woods__Extractor_extract_all_concurrent -->|construction: new| Mutex
  Woods__Extractor_extract_all_concurrent -->|construction: new| Thread
  Woods__Extractor_extract_all_concurrent -->|construction: new| extractor_class
  Woods__Extractor_precompute_flows(["new"])
  Woods__Extractor_precompute_flows -->|construction: new| FlowPrecomputer
  Woods__Extractor_parse_git_log_output(["new"])
  Woods__Extractor_parse_git_log_output -->|construction: new| Hash
  Woods__Extractor_write_dependency_graph[/"serialization"/]
  Woods__Extractor_write_dependency_graph -->|serialization: to_h| _dependency_graph
  Woods__Extractor_write_structural_summary[/"serialization"/]
  Woods__Extractor_write_structural_summary -->|serialization: to_h| _dependency_graph
  Woods__Extractor_regenerate_type_index[\"deserialization"\]
  Woods__Extractor_regenerate_type_index -->|deserialization: parse| JSON
  Woods__Extractor_re_extract_unit(["to_h"])
  Woods__Extractor_re_extract_unit -->|serialization: to_h| _dependency_graph
  Woods__Extractor_re_extract_unit -->|construction: new| EXTRACTORS___
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors(["new"])
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__ActionCableExtractor(["new"])
  Woods__Extractors__ActionCableExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__ActionCableExtractor_extract_channel(["new"])
  Woods__Extractors__ActionCableExtractor_extract_channel -->|construction: new| ExtractedUnit
  Ast__MethodExtractor["Ast::MethodExtractor"]
  Woods -->|construction: new| Ast__MethodExtractor
  Woods__Extractors -->|construction: new| Ast__MethodExtractor
  Woods__Extractors__AstSourceExtraction(["new"])
  Woods__Extractors__AstSourceExtraction -->|construction: new| Ast__MethodExtractor
  Woods__Extractors__AstSourceExtraction_extract_action_source(["new"])
  Woods__Extractors__AstSourceExtraction_extract_action_source -->|construction: new| Ast__MethodExtractor
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__BehavioralProfile(["new"])
  Woods__Extractors__BehavioralProfile -->|construction: new| ExtractedUnit
  Woods__Extractors__BehavioralProfile_build_unit(["new"])
  Woods__Extractors__BehavioralProfile_build_unit -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__CachingExtractor(["new"])
  Woods__Extractors__CachingExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__CachingExtractor_extract_caching_file(["new"])
  Woods__Extractors__CachingExtractor_extract_caching_file -->|construction: new| ExtractedUnit
  Ast__Parser["Ast::Parser"]
  Woods -->|construction: new| Ast__Parser
  FlowAnalysis__OperationExtractor["FlowAnalysis::OperationExtractor"]
  Woods -->|construction: new| FlowAnalysis__OperationExtractor
  Woods -->|deserialization: parse| _parser
  Woods -->|construction: new| Set
  columns["columns"]
  Woods -->|serialization: to_a| columns
  Woods__Extractors -->|construction: new| Ast__Parser
  Woods__Extractors -->|construction: new| FlowAnalysis__OperationExtractor
  Woods__Extractors -->|deserialization: parse| _parser
  Woods__Extractors -->|construction: new| Set
  Woods__Extractors -->|serialization: to_a| columns
  Woods__Extractors__CallbackAnalyzer(["new"])
  Woods__Extractors__CallbackAnalyzer -->|construction: new| Ast__Parser
  Woods__Extractors__CallbackAnalyzer -->|construction: new| FlowAnalysis__OperationExtractor
  Woods__Extractors__CallbackAnalyzer -->|deserialization: parse| _parser
  Woods__Extractors__CallbackAnalyzer -->|construction: new| Set
  Woods__Extractors__CallbackAnalyzer -->|serialization: to_a| columns
  Woods__Extractors__CallbackAnalyzer_initialize(["new"])
  Woods__Extractors__CallbackAnalyzer_initialize -->|construction: new| Ast__Parser
  Woods__Extractors__CallbackAnalyzer_initialize -->|construction: new| FlowAnalysis__OperationExtractor
  Woods__Extractors__CallbackAnalyzer_safe_parse[\"deserialization"\]
  Woods__Extractors__CallbackAnalyzer_safe_parse -->|deserialization: parse| _parser
  Woods__Extractors__CallbackAnalyzer_detect_columns_written(["new"])
  Woods__Extractors__CallbackAnalyzer_detect_columns_written -->|construction: new| Set
  Woods__Extractors__CallbackAnalyzer_detect_columns_written -->|serialization: to_a| columns
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__ConcernExtractor(["new"])
  Woods__Extractors__ConcernExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__ConcernExtractor_extract_concern_file(["new"])
  Woods__Extractors__ConcernExtractor_extract_concern_file -->|construction: new| ExtractedUnit
  BehavioralProfile["BehavioralProfile"]
  Woods -->|construction: new| BehavioralProfile
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| BehavioralProfile
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__ConfigurationExtractor(["new"])
  Woods__Extractors__ConfigurationExtractor -->|construction: new| BehavioralProfile
  Woods__Extractors__ConfigurationExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__ConfigurationExtractor_extract_all(["new"])
  Woods__Extractors__ConfigurationExtractor_extract_all -->|construction: new| BehavioralProfile
  Woods__Extractors__ConfigurationExtractor_extract_configuration_file(["new"])
  Woods__Extractors__ConfigurationExtractor_extract_configuration_file -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  actions["actions"]
  Woods -->|serialization: to_a| actions
  controller_action_methods["controller.action_methods"]
  Woods -->|serialization: to_a| controller_action_methods
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors -->|serialization: to_a| actions
  Woods__Extractors -->|serialization: to_a| controller_action_methods
  Woods__Extractors__ControllerExtractor(["new"])
  Woods__Extractors__ControllerExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__ControllerExtractor -->|serialization: to_a| actions
  Woods__Extractors__ControllerExtractor -->|serialization: to_a| controller_action_methods
  Woods__Extractors__ControllerExtractor_extract_controller(["new"])
  Woods__Extractors__ControllerExtractor_extract_controller -->|construction: new| ExtractedUnit
  Woods__Extractors__ControllerExtractor_extract_action_filter_actions[/"serialization"/]
  Woods__Extractors__ControllerExtractor_extract_action_filter_actions -->|serialization: to_a| actions
  Woods__Extractors__ControllerExtractor_extract_metadata[/"serialization"/]
  Woods__Extractors__ControllerExtractor_extract_metadata -->|serialization: to_a| controller_action_methods
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__DatabaseViewExtractor(["new"])
  Woods__Extractors__DatabaseViewExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__DatabaseViewExtractor_extract_view_file(["new"])
  Woods__Extractors__DatabaseViewExtractor_extract_view_file -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__DecoratorExtractor(["new"])
  Woods__Extractors__DecoratorExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__DecoratorExtractor_extract_decorator_file(["new"])
  Woods__Extractors__DecoratorExtractor_extract_decorator_file -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods -->|construction: new| Set
  controllers["controllers"]
  Woods -->|serialization: to_a| controllers
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| Set
  Woods__Extractors -->|serialization: to_a| controllers
  Woods__Extractors__EngineExtractor(["new"])
  Woods__Extractors__EngineExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__EngineExtractor -->|construction: new| Set
  Woods__Extractors__EngineExtractor -->|serialization: to_a| controllers
  Woods__Extractors__EngineExtractor_extract_engine(["new"])
  Woods__Extractors__EngineExtractor_extract_engine -->|construction: new| ExtractedUnit
  Woods__Extractors__EngineExtractor_extract_engine_controllers(["new"])
  Woods__Extractors__EngineExtractor_extract_engine_controllers -->|construction: new| Set
  Woods__Extractors__EngineExtractor_extract_engine_controllers -->|serialization: to_a| controllers
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__EventExtractor(["new"])
  Woods__Extractors__EventExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__EventExtractor_build_unit(["new"])
  Woods__Extractors__EventExtractor_build_unit -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__FactoryExtractor(["new"])
  Woods__Extractors__FactoryExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__FactoryExtractor_build_unit(["new"])
  Woods__Extractors__FactoryExtractor_build_unit -->|construction: new| ExtractedUnit
  Woods -->|construction: new| Set
  Woods -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| Set
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__GraphQLExtractor(["new"])
  Woods__Extractors__GraphQLExtractor -->|construction: new| Set
  Woods__Extractors__GraphQLExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__GraphQLExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__GraphQLExtractor_extract_all(["new"])
  Woods__Extractors__GraphQLExtractor_extract_all -->|construction: new| Set
  Woods__Extractors__GraphQLExtractor_extract_graphql_file(["new"])
  Woods__Extractors__GraphQLExtractor_extract_graphql_file -->|construction: new| ExtractedUnit
  Woods__Extractors__GraphQLExtractor_extract_from_runtime_type(["new"])
  Woods__Extractors__GraphQLExtractor_extract_from_runtime_type -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__I18nExtractor(["new"])
  Woods__Extractors__I18nExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__I18nExtractor_extract_i18n_file(["new"])
  Woods__Extractors__I18nExtractor_extract_i18n_file -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__JobExtractor(["new"])
  Woods__Extractors__JobExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__JobExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__JobExtractor_extract_job_file(["new"])
  Woods__Extractors__JobExtractor_extract_job_file -->|construction: new| ExtractedUnit
  Woods__Extractors__JobExtractor_extract_job_class(["new"])
  Woods__Extractors__JobExtractor_extract_job_class -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  mailer_action_methods["mailer.action_methods"]
  Woods -->|serialization: to_a| mailer_action_methods
  Woods -->|serialization: to_a| mailer_action_methods
  Woods -->|serialization: to_a| actions
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors -->|serialization: to_a| mailer_action_methods
  Woods__Extractors -->|serialization: to_a| mailer_action_methods
  Woods__Extractors -->|serialization: to_a| actions
  Woods__Extractors__MailerExtractor(["new"])
  Woods__Extractors__MailerExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__MailerExtractor -->|serialization: to_a| mailer_action_methods
  Woods__Extractors__MailerExtractor -->|serialization: to_a| mailer_action_methods
  Woods__Extractors__MailerExtractor -->|serialization: to_a| actions
  Woods__Extractors__MailerExtractor_extract_mailer(["new"])
  Woods__Extractors__MailerExtractor_extract_mailer -->|construction: new| ExtractedUnit
  Woods__Extractors__MailerExtractor_annotate_source[/"serialization"/]
  Woods__Extractors__MailerExtractor_annotate_source -->|serialization: to_a| mailer_action_methods
  Woods__Extractors__MailerExtractor_extract_metadata[/"serialization"/]
  Woods__Extractors__MailerExtractor_extract_metadata -->|serialization: to_a| mailer_action_methods
  Woods__Extractors__MailerExtractor_extract_action_filter_actions[/"serialization"/]
  Woods__Extractors__MailerExtractor_extract_action_filter_actions -->|serialization: to_a| actions
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__ManagerExtractor(["new"])
  Woods__Extractors__ManagerExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__ManagerExtractor_extract_manager_file(["new"])
  Woods__Extractors__ManagerExtractor_extract_manager_file -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__MiddlewareExtractor(["new"])
  Woods__Extractors__MiddlewareExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__MiddlewareExtractor_extract_all(["new"])
  Woods__Extractors__MiddlewareExtractor_extract_all -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods -->|construction: new| Hash
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| Hash
  Woods__Extractors__MigrationExtractor(["new"])
  Woods__Extractors__MigrationExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__MigrationExtractor -->|construction: new| Hash
  Woods__Extractors__MigrationExtractor_extract_migration_file(["new"])
  Woods__Extractors__MigrationExtractor_extract_migration_file -->|construction: new| ExtractedUnit
  Woods__Extractors__MigrationExtractor_extract_operations(["new"])
  Woods__Extractors__MigrationExtractor_extract_operations -->|construction: new| Hash
  Woods -->|construction: new| ExtractedUnit
  Woods -->|construction: new| Ast__Parser
  parser["parser"]
  Woods -->|deserialization: parse| parser
  CallbackAnalyzer["CallbackAnalyzer"]
  Woods -->|construction: new| CallbackAnalyzer
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| Ast__Parser
  Woods__Extractors -->|deserialization: parse| parser
  Woods__Extractors -->|construction: new| CallbackAnalyzer
  Woods__Extractors__ModelExtractor(["new"])
  Woods__Extractors__ModelExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__ModelExtractor -->|construction: new| Ast__Parser
  Woods__Extractors__ModelExtractor -->|deserialization: parse| parser
  Woods__Extractors__ModelExtractor -->|construction: new| CallbackAnalyzer
  Woods__Extractors__ModelExtractor_extract_model(["new"])
  Woods__Extractors__ModelExtractor_extract_model -->|construction: new| ExtractedUnit
  Woods__Extractors__ModelExtractor_extract_scopes(["new"])
  Woods__Extractors__ModelExtractor_extract_scopes -->|construction: new| Ast__Parser
  Woods__Extractors__ModelExtractor_extract_scopes -->|deserialization: parse| parser
  Woods__Extractors__ModelExtractor_enrich_callbacks_with_side_effects(["new"])
  Woods__Extractors__ModelExtractor_enrich_callbacks_with_side_effects -->|construction: new| CallbackAnalyzer
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__PhlexExtractor(["new"])
  Woods__Extractors__PhlexExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__PhlexExtractor_extract_component(["new"])
  Woods__Extractors__PhlexExtractor_extract_component -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__PolicyExtractor(["new"])
  Woods__Extractors__PolicyExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__PolicyExtractor_extract_policy_file(["new"])
  Woods__Extractors__PolicyExtractor_extract_policy_file -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__PunditExtractor(["new"])
  Woods__Extractors__PunditExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__PunditExtractor_extract_pundit_file(["new"])
  Woods__Extractors__PunditExtractor_extract_pundit_file -->|construction: new| ExtractedUnit
  Woods -->|construction: new| Pathname
  Woods -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| Pathname
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__RailsSourceExtractor(["new"])
  Woods__Extractors__RailsSourceExtractor -->|construction: new| Pathname
  Woods__Extractors__RailsSourceExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__RailsSourceExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__RailsSourceExtractor_find_gem_path(["new"])
  Woods__Extractors__RailsSourceExtractor_find_gem_path -->|construction: new| Pathname
  Woods__Extractors__RailsSourceExtractor_extract_framework_file(["new"])
  Woods__Extractors__RailsSourceExtractor_extract_framework_file -->|construction: new| ExtractedUnit
  Woods__Extractors__RailsSourceExtractor_extract_gem_file(["new"])
  Woods__Extractors__RailsSourceExtractor_extract_gem_file -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__RakeTaskExtractor(["new"])
  Woods__Extractors__RakeTaskExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__RakeTaskExtractor_build_unit(["new"])
  Woods__Extractors__RakeTaskExtractor_build_unit -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__RouteExtractor(["new"])
  Woods__Extractors__RouteExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__RouteExtractor_extract_route(["new"])
  Woods__Extractors__RouteExtractor_extract_route -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__ScheduledJobExtractor(["new"])
  Woods__Extractors__ScheduledJobExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__ScheduledJobExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__ScheduledJobExtractor_build_yaml_unit(["new"])
  Woods__Extractors__ScheduledJobExtractor_build_yaml_unit -->|construction: new| ExtractedUnit
  Woods__Extractors__ScheduledJobExtractor_build_whenever_unit(["new"])
  Woods__Extractors__ScheduledJobExtractor_build_whenever_unit -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__SerializerExtractor(["new"])
  Woods__Extractors__SerializerExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__SerializerExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__SerializerExtractor_extract_serializer_file(["new"])
  Woods__Extractors__SerializerExtractor_extract_serializer_file -->|construction: new| ExtractedUnit
  Woods__Extractors__SerializerExtractor_extract_serializer_class(["new"])
  Woods__Extractors__SerializerExtractor_extract_serializer_class -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__ServiceExtractor(["new"])
  Woods__Extractors__ServiceExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__ServiceExtractor_extract_service_file(["new"])
  Woods__Extractors__ServiceExtractor_extract_service_file -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__StateMachineExtractor(["new"])
  Woods__Extractors__StateMachineExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__StateMachineExtractor_build_unit(["new"])
  Woods__Extractors__StateMachineExtractor_build_unit -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__TestMappingExtractor(["new"])
  Woods__Extractors__TestMappingExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__TestMappingExtractor_extract_test_file(["new"])
  Woods__Extractors__TestMappingExtractor_extract_test_file -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__ValidatorExtractor(["new"])
  Woods__Extractors__ValidatorExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__ValidatorExtractor_extract_validator_file(["new"])
  Woods__Extractors__ValidatorExtractor_extract_validator_file -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__ViewComponentExtractor(["new"])
  Woods__Extractors__ViewComponentExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__ViewComponentExtractor_extract_component(["new"])
  Woods__Extractors__ViewComponentExtractor_extract_component -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods -->|construction: new| Set
  partials["partials"]
  Woods -->|serialization: to_a| partials
  Woods -->|construction: new| Set
  found["found"]
  Woods -->|serialization: to_a| found
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| Set
  Woods__Extractors -->|serialization: to_a| partials
  Woods__Extractors -->|construction: new| Set
  Woods__Extractors -->|serialization: to_a| found
  Woods__Extractors__ViewTemplateExtractor(["new"])
  Woods__Extractors__ViewTemplateExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__ViewTemplateExtractor -->|construction: new| Set
  Woods__Extractors__ViewTemplateExtractor -->|serialization: to_a| partials
  Woods__Extractors__ViewTemplateExtractor -->|construction: new| Set
  Woods__Extractors__ViewTemplateExtractor -->|serialization: to_a| found
  Woods__Extractors__ViewTemplateExtractor_extract_view_template_file(["new"])
  Woods__Extractors__ViewTemplateExtractor_extract_view_template_file -->|construction: new| ExtractedUnit
  Woods__Extractors__ViewTemplateExtractor_extract_rendered_partials(["new"])
  Woods__Extractors__ViewTemplateExtractor_extract_rendered_partials -->|construction: new| Set
  Woods__Extractors__ViewTemplateExtractor_extract_rendered_partials -->|serialization: to_a| partials
  Woods__Extractors__ViewTemplateExtractor_extract_helpers(["new"])
  Woods__Extractors__ViewTemplateExtractor_extract_helpers -->|construction: new| Set
  Woods__Extractors__ViewTemplateExtractor_extract_helpers -->|serialization: to_a| found
  Woods -->|construction: new| Hash
  Woods -->|construction: new| Hash
  Woods__Feedback(["new"])
  Woods__Feedback -->|construction: new| Hash
  Woods__Feedback -->|construction: new| Hash
  Woods__Feedback__GapDetector(["new"])
  Woods__Feedback__GapDetector -->|construction: new| Hash
  Woods__Feedback__GapDetector -->|construction: new| Hash
  Woods__Feedback__GapDetector_count_keywords(["new"])
  Woods__Feedback__GapDetector_count_keywords -->|construction: new| Hash
  Woods__Feedback__GapDetector_detect_frequently_missing(["new"])
  Woods__Feedback__GapDetector_detect_frequently_missing -->|construction: new| Hash
  Woods -->|deserialization: parse| JSON
  Woods__Feedback -->|deserialization: parse| JSON
  Woods__Feedback__Store[\"deserialization"\]
  Woods__Feedback__Store -->|deserialization: parse| JSON
  Woods__Feedback__Store_all_entries[\"deserialization"\]
  Woods__Feedback__Store_all_entries -->|deserialization: parse| JSON
  Woods -->|construction: new| Ast__Parser
  Woods -->|construction: new| Ast__MethodExtractor
  Woods -->|construction: new| FlowAnalysis__OperationExtractor
  Woods -->|construction: new| Set
  FlowDocument["FlowDocument"]
  Woods -->|construction: new| FlowDocument
  Woods -->|deserialization: parse| _parser
  Woods -->|deserialization: parse| JSON
  Woods__FlowAssembler(["new"])
  Woods__FlowAssembler -->|construction: new| Ast__Parser
  Woods__FlowAssembler -->|construction: new| Ast__MethodExtractor
  Woods__FlowAssembler -->|construction: new| FlowAnalysis__OperationExtractor
  Woods__FlowAssembler -->|construction: new| Set
  Woods__FlowAssembler -->|construction: new| FlowDocument
  Woods__FlowAssembler -->|deserialization: parse| _parser
  Woods__FlowAssembler -->|deserialization: parse| JSON
  Woods__FlowAssembler_initialize(["new"])
  Woods__FlowAssembler_initialize -->|construction: new| Ast__Parser
  Woods__FlowAssembler_initialize -->|construction: new| Ast__MethodExtractor
  Woods__FlowAssembler_initialize -->|construction: new| FlowAnalysis__OperationExtractor
  Woods__FlowAssembler_assemble(["new"])
  Woods__FlowAssembler_assemble -->|construction: new| Set
  Woods__FlowAssembler_assemble -->|construction: new| FlowDocument
  Woods__FlowAssembler_extract_operations[\"deserialization"\]
  Woods__FlowAssembler_extract_operations -->|deserialization: parse| _parser
  Woods__FlowAssembler_load_unit[\"deserialization"\]
  Woods__FlowAssembler_load_unit -->|deserialization: parse| JSON
  Woods__FlowDocument(["new"])
  Woods__FlowDocument_from_h(["new"])
  FlowAssembler["FlowAssembler"]
  Woods -->|construction: new| FlowAssembler
  Woods__FlowPrecomputer(["new"])
  Woods__FlowPrecomputer -->|construction: new| FlowAssembler
  Woods__FlowPrecomputer_precompute(["new"])
  Woods__FlowPrecomputer_precompute -->|construction: new| FlowAssembler
  Woods -->|construction: new| Hash
  Random["Random"]
  Woods -->|construction: new| Random
  _graph["@graph"]
  Woods -->|serialization: to_h| _graph
  Woods -->|construction: new| Hash
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  pairs["pairs"]
  Woods -->|serialization: to_a| pairs
  Woods -->|construction: new| Set
  Woods__GraphAnalyzer(["new"])
  Woods__GraphAnalyzer -->|construction: new| Hash
  Woods__GraphAnalyzer -->|construction: new| Random
  Woods__GraphAnalyzer -->|serialization: to_h| _graph
  Woods__GraphAnalyzer -->|construction: new| Hash
  Woods__GraphAnalyzer -->|construction: new| Set
  Woods__GraphAnalyzer -->|construction: new| Set
  Woods__GraphAnalyzer -->|serialization: to_a| pairs
  Woods__GraphAnalyzer -->|construction: new| Set
  Woods__GraphAnalyzer_bridges(["new"])
  Woods__GraphAnalyzer_bridges -->|construction: new| Hash
  Woods__GraphAnalyzer_bridges -->|construction: new| Random
  Woods__GraphAnalyzer_graph_data[/"serialization"/]
  Woods__GraphAnalyzer_graph_data -->|serialization: to_h| _graph
  Woods__GraphAnalyzer_detect_cycles(["new"])
  Woods__GraphAnalyzer_detect_cycles -->|construction: new| Hash
  Woods__GraphAnalyzer_detect_cycles -->|construction: new| Set
  Woods__GraphAnalyzer_generate_sample_pairs(["new"])
  Woods__GraphAnalyzer_generate_sample_pairs -->|construction: new| Set
  Woods__GraphAnalyzer_generate_sample_pairs -->|serialization: to_a| pairs
  Woods__GraphAnalyzer_bfs_shortest_path(["new"])
  Woods__GraphAnalyzer_bfs_shortest_path -->|construction: new| Set
  Woods -->|construction: new| Pathname
  Regexp["Regexp"]
  Woods -->|construction: new| Regexp
  Woods -->|construction: new| Regexp
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| Set
  Woods__MCP(["new"])
  Woods__MCP -->|construction: new| Pathname
  Woods__MCP -->|construction: new| Regexp
  Woods__MCP -->|construction: new| Regexp
  Woods__MCP -->|deserialization: parse| JSON
  Woods__MCP -->|deserialization: parse| JSON
  Woods__MCP -->|deserialization: parse| JSON
  Woods__MCP -->|construction: new| Set
  Woods__MCP__IndexReader(["new"])
  Woods__MCP__IndexReader -->|construction: new| Pathname
  Woods__MCP__IndexReader -->|construction: new| Regexp
  Woods__MCP__IndexReader -->|construction: new| Regexp
  Woods__MCP__IndexReader -->|deserialization: parse| JSON
  Woods__MCP__IndexReader -->|deserialization: parse| JSON
  Woods__MCP__IndexReader -->|deserialization: parse| JSON
  Woods__MCP__IndexReader -->|construction: new| Set
  Woods__MCP__IndexReader_initialize(["new"])
  Woods__MCP__IndexReader_initialize -->|construction: new| Pathname
  Woods__MCP__IndexReader_search(["new"])
  Woods__MCP__IndexReader_search -->|construction: new| Regexp
  Woods__MCP__IndexReader_framework_sources(["new"])
  Woods__MCP__IndexReader_framework_sources -->|construction: new| Regexp
  Woods__MCP__IndexReader_read_index[\"deserialization"\]
  Woods__MCP__IndexReader_read_index -->|deserialization: parse| JSON
  Woods__MCP__IndexReader_load_unit[\"deserialization"\]
  Woods__MCP__IndexReader_load_unit -->|deserialization: parse| JSON
  Woods__MCP__IndexReader_parse_json[\"deserialization"\]
  Woods__MCP__IndexReader_parse_json -->|deserialization: parse| JSON
  Woods__MCP__IndexReader_traverse(["new"])
  Woods__MCP__IndexReader_traverse -->|construction: new| Set
  IndexReader["IndexReader"]
  Woods -->|construction: new| IndexReader
  Woods -->|construction: new| MCP__Server
  Woods -->|construction: new| MCP__Tool__Response
  Woods -->|construction: new| Woods__FlowAssembler
  Woods__SessionTracer__SessionFlowAssembler["Woods::SessionTracer::SessionFlowAssembler"]
  Woods -->|construction: new| Woods__SessionTracer__SessionFlowAssembler
  Woods -->|construction: new| Thread
  Woods -->|construction: new| Woods__Extractor
  Logger["Logger"]
  Woods -->|construction: new| Logger
  Woods -->|construction: new| Thread
  Woods -->|construction: new| Woods__Builder
  Woods__Embedding__TextPreparer["Woods::Embedding::TextPreparer"]
  Woods -->|construction: new| Woods__Embedding__TextPreparer
  Woods -->|construction: new| Woods__Embedding__Indexer
  Woods -->|construction: new| Logger
  StandardError["StandardError"]
  Woods -->|construction: new| StandardError
  Woods -->|construction: new| Woods__Feedback__GapDetector
  MCP__ResourceTemplate["MCP::ResourceTemplate"]
  Woods -->|construction: new| MCP__ResourceTemplate
  Woods -->|construction: new| MCP__ResourceTemplate
  MCP__Resource["MCP::Resource"]
  Woods -->|construction: new| MCP__Resource
  Woods -->|construction: new| MCP__Resource
  Woods__MCP -->|construction: new| IndexReader
  Woods__MCP -->|construction: new| MCP__Server
  Woods__MCP -->|construction: new| MCP__Tool__Response
  Woods__MCP -->|construction: new| Woods__FlowAssembler
  Woods__MCP -->|construction: new| Woods__SessionTracer__SessionFlowAssembler
  Woods__MCP -->|construction: new| Thread
  Woods__MCP -->|construction: new| Woods__Extractor
  Woods__MCP -->|construction: new| Logger
  Woods__MCP -->|construction: new| Thread
  Woods__MCP -->|construction: new| Woods__Builder
  Woods__MCP -->|construction: new| Woods__Embedding__TextPreparer
  Woods__MCP -->|construction: new| Woods__Embedding__Indexer
  Woods__MCP -->|construction: new| Logger
  Woods__MCP -->|construction: new| StandardError
  Woods__MCP -->|construction: new| Woods__Feedback__GapDetector
  Woods__MCP -->|construction: new| MCP__ResourceTemplate
  Woods__MCP -->|construction: new| MCP__ResourceTemplate
  Woods__MCP -->|construction: new| MCP__Resource
  Woods__MCP -->|construction: new| MCP__Resource
  Woods__MCP__Server(["new"])
  Woods__MCP__Server -->|construction: new| IndexReader
  Woods__MCP__Server -->|construction: new| MCP__Server
  Woods__MCP__Server -->|construction: new| MCP__Tool__Response
  Woods__MCP__Server -->|construction: new| Woods__FlowAssembler
  Woods__MCP__Server -->|construction: new| Woods__SessionTracer__SessionFlowAssembler
  Woods__MCP__Server -->|construction: new| Thread
  Woods__MCP__Server -->|construction: new| Woods__Extractor
  Woods__MCP__Server -->|construction: new| Logger
  Woods__MCP__Server -->|construction: new| Thread
  Woods__MCP__Server -->|construction: new| Woods__Builder
  Woods__MCP__Server -->|construction: new| Woods__Embedding__TextPreparer
  Woods__MCP__Server -->|construction: new| Woods__Embedding__Indexer
  Woods__MCP__Server -->|construction: new| Logger
  Woods__MCP__Server -->|construction: new| StandardError
  Woods__MCP__Server -->|construction: new| Woods__Feedback__GapDetector
  Woods__MCP__Server -->|construction: new| MCP__ResourceTemplate
  Woods__MCP__Server -->|construction: new| MCP__ResourceTemplate
  Woods__MCP__Server -->|construction: new| MCP__Resource
  Woods__MCP__Server -->|construction: new| MCP__Resource
  Woods -->|construction: new| Struct
  HealthStatus["HealthStatus"]
  Woods -->|construction: new| HealthStatus
  Woods__Observability(["new"])
  Woods__Observability -->|construction: new| Struct
  Woods__Observability -->|construction: new| HealthStatus
  Woods__Observability__HealthCheck(["new"])
  Woods__Observability__HealthCheck -->|construction: new| Struct
  Woods__Observability__HealthCheck -->|construction: new| HealthStatus
  Woods__Observability__HealthCheck_run(["new"])
  Woods__Observability__HealthCheck_run -->|construction: new| HealthStatus
  Woods -->|deserialization: parse| JSON
  Time["Time"]
  Woods -->|deserialization: parse| Time
  Woods -->|deserialization: parse| JSON
  Woods__Operator[\"deserialization"\]
  Woods__Operator -->|deserialization: parse| JSON
  Woods__Operator -->|deserialization: parse| Time
  Woods__Operator -->|deserialization: parse| JSON
  Woods__Operator__PipelineGuard[\"deserialization"\]
  Woods__Operator__PipelineGuard -->|deserialization: parse| JSON
  Woods__Operator__PipelineGuard -->|deserialization: parse| Time
  Woods__Operator__PipelineGuard -->|deserialization: parse| JSON
  Woods__Operator__PipelineGuard_record_[\"deserialization"\]
  Woods__Operator__PipelineGuard_record_ -->|deserialization: parse| JSON
  Woods__Operator__PipelineGuard_last_run[\"deserialization"\]
  Woods__Operator__PipelineGuard_last_run -->|deserialization: parse| Time
  Woods__Operator__PipelineGuard_read_state[\"deserialization"\]
  Woods__Operator__PipelineGuard_read_state -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods__Operator -->|deserialization: parse| JSON
  Woods__Operator__StatusReporter[\"deserialization"\]
  Woods__Operator__StatusReporter -->|deserialization: parse| JSON
  Woods__Operator__StatusReporter_read_manifest[\"deserialization"\]
  Woods__Operator__StatusReporter_read_manifest -->|deserialization: parse| JSON
  Woods -->|construction: new| Mutex
  Woods__Resilience(["new"])
  Woods__Resilience -->|construction: new| Mutex
  Woods__Resilience__CircuitBreaker(["new"])
  Woods__Resilience__CircuitBreaker -->|construction: new| Mutex
  Woods__Resilience__CircuitBreaker_initialize(["new"])
  Woods__Resilience__CircuitBreaker_initialize -->|construction: new| Mutex
  Woods -->|construction: new| Struct
  ValidationReport["ValidationReport"]
  Woods -->|construction: new| ValidationReport
  Woods -->|construction: new| ValidationReport
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| Set
  Woods -->|deserialization: parse| JSON
  Woods__Resilience -->|construction: new| Struct
  Woods__Resilience -->|construction: new| ValidationReport
  Woods__Resilience -->|construction: new| ValidationReport
  Woods__Resilience -->|deserialization: parse| JSON
  Woods__Resilience -->|construction: new| Set
  Woods__Resilience -->|deserialization: parse| JSON
  Woods__Resilience__IndexValidator(["new"])
  Woods__Resilience__IndexValidator -->|construction: new| Struct
  Woods__Resilience__IndexValidator -->|construction: new| ValidationReport
  Woods__Resilience__IndexValidator -->|construction: new| ValidationReport
  Woods__Resilience__IndexValidator -->|deserialization: parse| JSON
  Woods__Resilience__IndexValidator -->|construction: new| Set
  Woods__Resilience__IndexValidator -->|deserialization: parse| JSON
  Woods__Resilience__IndexValidator_validate(["new"])
  Woods__Resilience__IndexValidator_validate -->|construction: new| ValidationReport
  Woods__Resilience__IndexValidator_validate -->|construction: new| ValidationReport
  Woods__Resilience__IndexValidator_validate_type_directory(["parse"])
  Woods__Resilience__IndexValidator_validate_type_directory -->|deserialization: parse| JSON
  Woods__Resilience__IndexValidator_validate_type_directory -->|construction: new| Set
  Woods__Resilience__IndexValidator_validate_content_hash[\"deserialization"\]
  Woods__Resilience__IndexValidator_validate_content_hash -->|deserialization: parse| JSON
  AssembledContext["AssembledContext"]
  Woods -->|construction: new| AssembledContext
  Woods -->|construction: new| Struct
  Woods__Retrieval(["new"])
  Woods__Retrieval -->|construction: new| AssembledContext
  Woods__Retrieval -->|construction: new| Struct
  Woods__Retrieval__ContextAssembler(["new"])
  Woods__Retrieval__ContextAssembler -->|construction: new| AssembledContext
  Woods__Retrieval__ContextAssembler_build_result(["new"])
  Woods__Retrieval__ContextAssembler_build_result -->|construction: new| AssembledContext
  Woods -->|construction: new| Struct
  Woods -->|construction: new| Set
  Classification["Classification"]
  Woods -->|construction: new| Classification
  Woods__Retrieval -->|construction: new| Struct
  Woods__Retrieval -->|construction: new| Set
  Woods__Retrieval -->|construction: new| Classification
  Woods__Retrieval__QueryClassifier(["new"])
  Woods__Retrieval__QueryClassifier -->|construction: new| Struct
  Woods__Retrieval__QueryClassifier -->|construction: new| Set
  Woods__Retrieval__QueryClassifier -->|construction: new| Classification
  Woods__Retrieval__QueryClassifier_classify(["new"])
  Woods__Retrieval__QueryClassifier_classify -->|construction: new| Classification
  Woods -->|construction: new| Hash
  Woods -->|construction: new| Hash
  Woods -->|construction: new| Hash
  SearchExecutor__Candidate["SearchExecutor::Candidate"]
  Woods -->|construction: new| SearchExecutor__Candidate
  Woods__Retrieval -->|construction: new| Hash
  Woods__Retrieval -->|construction: new| Hash
  Woods__Retrieval -->|construction: new| Hash
  Woods__Retrieval -->|construction: new| SearchExecutor__Candidate
  Woods__Retrieval__Ranker(["new"])
  Woods__Retrieval__Ranker -->|construction: new| Hash
  Woods__Retrieval__Ranker -->|construction: new| Hash
  Woods__Retrieval__Ranker -->|construction: new| Hash
  Woods__Retrieval__Ranker -->|construction: new| SearchExecutor__Candidate
  Woods__Retrieval__Ranker_compute_rrf_scores(["new"])
  Woods__Retrieval__Ranker_compute_rrf_scores -->|construction: new| Hash
  Woods__Retrieval__Ranker_apply_diversity_penalty(["new"])
  Woods__Retrieval__Ranker_apply_diversity_penalty -->|construction: new| Hash
  Woods__Retrieval__Ranker_apply_diversity_penalty -->|construction: new| Hash
  Woods__Retrieval__Ranker_build_candidate(["new"])
  Woods__Retrieval__Ranker_build_candidate -->|construction: new| SearchExecutor__Candidate
  Woods -->|construction: new| Struct
  Woods -->|construction: new| Struct
  ExecutionResult["ExecutionResult"]
  Woods -->|construction: new| ExecutionResult
  Candidate["Candidate"]
  Woods -->|construction: new| Candidate
  Woods -->|construction: new| Candidate
  Woods__Retrieval -->|construction: new| Struct
  Woods__Retrieval -->|construction: new| Struct
  Woods__Retrieval -->|construction: new| ExecutionResult
  Woods__Retrieval -->|construction: new| Candidate
  Woods__Retrieval -->|construction: new| Candidate
  Woods__Retrieval__SearchExecutor(["new"])
  Woods__Retrieval__SearchExecutor -->|construction: new| Struct
  Woods__Retrieval__SearchExecutor -->|construction: new| Struct
  Woods__Retrieval__SearchExecutor -->|construction: new| ExecutionResult
  Woods__Retrieval__SearchExecutor -->|construction: new| Candidate
  Woods__Retrieval__SearchExecutor -->|construction: new| Candidate
  Woods__Retrieval__SearchExecutor_execute(["new"])
  Woods__Retrieval__SearchExecutor_execute -->|construction: new| ExecutionResult
  Woods__Retrieval__SearchExecutor_execute_vector(["new"])
  Woods__Retrieval__SearchExecutor_execute_vector -->|construction: new| Candidate
  Woods__Retrieval__SearchExecutor_rank_keyword_results(["new"])
  Woods__Retrieval__SearchExecutor_rank_keyword_results -->|construction: new| Candidate
  Woods -->|construction: new| Struct
  Woods -->|construction: new| Struct
  Retrieval__QueryClassifier["Retrieval::QueryClassifier"]
  Woods -->|construction: new| Retrieval__QueryClassifier
  Retrieval__SearchExecutor["Retrieval::SearchExecutor"]
  Woods -->|construction: new| Retrieval__SearchExecutor
  Retrieval__Ranker["Retrieval::Ranker"]
  Woods -->|construction: new| Retrieval__Ranker
  Retrieval__ContextAssembler["Retrieval::ContextAssembler"]
  Woods -->|construction: new| Retrieval__ContextAssembler
  RetrievalTrace["RetrievalTrace"]
  Woods -->|construction: new| RetrievalTrace
  RetrievalResult["RetrievalResult"]
  Woods -->|construction: new| RetrievalResult
  Woods__Retriever(["new"])
  Woods__Retriever -->|construction: new| Struct
  Woods__Retriever -->|construction: new| Struct
  Woods__Retriever -->|construction: new| Retrieval__QueryClassifier
  Woods__Retriever -->|construction: new| Retrieval__SearchExecutor
  Woods__Retriever -->|construction: new| Retrieval__Ranker
  Woods__Retriever -->|construction: new| Retrieval__ContextAssembler
  Woods__Retriever -->|construction: new| RetrievalTrace
  Woods__Retriever -->|construction: new| RetrievalResult
  Woods__Retriever_initialize(["new"])
  Woods__Retriever_initialize -->|construction: new| Retrieval__QueryClassifier
  Woods__Retriever_initialize -->|construction: new| Retrieval__SearchExecutor
  Woods__Retriever_initialize -->|construction: new| Retrieval__Ranker
  Woods__Retriever_initialize -->|construction: new| Retrieval__ContextAssembler
  Woods__Retriever_retrieve(["new"])
  Woods__Retriever_retrieve -->|construction: new| RetrievalTrace
  Woods__Retriever_build_result(["new"])
  Woods__Retriever_build_result -->|construction: new| RetrievalResult
  Woods -->|construction: new| Ast__Parser
  Woods -->|deserialization: parse| _parser
  Woods -->|construction: new| ExtractedUnit
  Woods__RubyAnalyzer(["new"])
  Woods__RubyAnalyzer -->|construction: new| Ast__Parser
  Woods__RubyAnalyzer -->|deserialization: parse| _parser
  Woods__RubyAnalyzer -->|construction: new| ExtractedUnit
  Woods__RubyAnalyzer__ClassAnalyzer(["new"])
  Woods__RubyAnalyzer__ClassAnalyzer -->|construction: new| Ast__Parser
  Woods__RubyAnalyzer__ClassAnalyzer -->|deserialization: parse| _parser
  Woods__RubyAnalyzer__ClassAnalyzer -->|construction: new| ExtractedUnit
  Woods__RubyAnalyzer__ClassAnalyzer_initialize(["new"])
  Woods__RubyAnalyzer__ClassAnalyzer_initialize -->|construction: new| Ast__Parser
  Woods__RubyAnalyzer__ClassAnalyzer_analyze[\"deserialization"\]
  Woods__RubyAnalyzer__ClassAnalyzer_analyze -->|deserialization: parse| _parser
  Woods__RubyAnalyzer__ClassAnalyzer_process_definition(["new"])
  Woods__RubyAnalyzer__ClassAnalyzer_process_definition -->|construction: new| ExtractedUnit
  Woods -->|construction: new| Ast__Parser
  Ast__CallSiteExtractor["Ast::CallSiteExtractor"]
  Woods -->|construction: new| Ast__CallSiteExtractor
  Woods -->|deserialization: parse| _parser
  Woods__RubyAnalyzer -->|construction: new| Ast__Parser
  Woods__RubyAnalyzer -->|construction: new| Ast__CallSiteExtractor
  Woods__RubyAnalyzer -->|deserialization: parse| _parser
  Woods__RubyAnalyzer__DataFlowAnalyzer(["new"])
  Woods__RubyAnalyzer__DataFlowAnalyzer -->|construction: new| Ast__Parser
  Woods__RubyAnalyzer__DataFlowAnalyzer -->|construction: new| Ast__CallSiteExtractor
  Woods__RubyAnalyzer__DataFlowAnalyzer -->|deserialization: parse| _parser
  Woods__RubyAnalyzer__DataFlowAnalyzer_initialize(["new"])
  Woods__RubyAnalyzer__DataFlowAnalyzer_initialize -->|construction: new| Ast__Parser
  Woods__RubyAnalyzer__DataFlowAnalyzer_initialize -->|construction: new| Ast__CallSiteExtractor
  Woods__RubyAnalyzer__DataFlowAnalyzer_detect_transformations[\"deserialization"\]
  Woods__RubyAnalyzer__DataFlowAnalyzer_detect_transformations -->|deserialization: parse| _parser
  Woods -->|construction: new| Ast__Parser
  Woods -->|construction: new| Ast__CallSiteExtractor
  Woods -->|deserialization: parse| _parser
  VisibilityTracker["VisibilityTracker"]
  Woods -->|construction: new| VisibilityTracker
  Woods -->|construction: new| ExtractedUnit
  Woods__RubyAnalyzer -->|construction: new| Ast__Parser
  Woods__RubyAnalyzer -->|construction: new| Ast__CallSiteExtractor
  Woods__RubyAnalyzer -->|deserialization: parse| _parser
  Woods__RubyAnalyzer -->|construction: new| VisibilityTracker
  Woods__RubyAnalyzer -->|construction: new| ExtractedUnit
  Woods__RubyAnalyzer__MethodAnalyzer(["new"])
  Woods__RubyAnalyzer__MethodAnalyzer -->|construction: new| Ast__Parser
  Woods__RubyAnalyzer__MethodAnalyzer -->|construction: new| Ast__CallSiteExtractor
  Woods__RubyAnalyzer__MethodAnalyzer -->|deserialization: parse| _parser
  Woods__RubyAnalyzer__MethodAnalyzer -->|construction: new| VisibilityTracker
  Woods__RubyAnalyzer__MethodAnalyzer -->|construction: new| ExtractedUnit
  Woods__RubyAnalyzer__MethodAnalyzer_initialize(["new"])
  Woods__RubyAnalyzer__MethodAnalyzer_initialize -->|construction: new| Ast__Parser
  Woods__RubyAnalyzer__MethodAnalyzer_initialize -->|construction: new| Ast__CallSiteExtractor
  Woods__RubyAnalyzer__MethodAnalyzer_analyze[\"deserialization"\]
  Woods__RubyAnalyzer__MethodAnalyzer_analyze -->|deserialization: parse| _parser
  Woods__RubyAnalyzer__MethodAnalyzer_process_container_methods(["new"])
  Woods__RubyAnalyzer__MethodAnalyzer_process_container_methods -->|construction: new| VisibilityTracker
  Woods__RubyAnalyzer__MethodAnalyzer_build_method_unit(["new"])
  Woods__RubyAnalyzer__MethodAnalyzer_build_method_unit -->|construction: new| ExtractedUnit
  TracePoint["TracePoint"]
  Woods -->|construction: new| TracePoint
  Woods -->|construction: new| Hash
  Woods__RubyAnalyzer -->|construction: new| TracePoint
  Woods__RubyAnalyzer -->|construction: new| Hash
  Woods__RubyAnalyzer__TraceEnricher(["new"])
  Woods__RubyAnalyzer__TraceEnricher -->|construction: new| TracePoint
  Woods__RubyAnalyzer__TraceEnricher -->|construction: new| Hash
  Woods__RubyAnalyzer__TraceEnricher_record(["new"])
  Woods__RubyAnalyzer__TraceEnricher_record -->|construction: new| TracePoint
  Woods -->|construction: new| Ast__Parser
  ClassAnalyzer["ClassAnalyzer"]
  Woods -->|construction: new| ClassAnalyzer
  MethodAnalyzer["MethodAnalyzer"]
  Woods -->|construction: new| MethodAnalyzer
  DataFlowAnalyzer["DataFlowAnalyzer"]
  Woods -->|construction: new| DataFlowAnalyzer
  Woods__RubyAnalyzer -->|construction: new| Ast__Parser
  Woods__RubyAnalyzer -->|construction: new| ClassAnalyzer
  Woods__RubyAnalyzer -->|construction: new| MethodAnalyzer
  Woods__RubyAnalyzer -->|construction: new| DataFlowAnalyzer
  Woods -->|deserialization: parse| JSON
  Woods__SessionTracer[\"deserialization"\]
  Woods__SessionTracer -->|deserialization: parse| JSON
  Woods__SessionTracer__FileStore[\"deserialization"\]
  Woods__SessionTracer__FileStore -->|deserialization: parse| JSON
  Woods__SessionTracer__FileStore_read[\"deserialization"\]
  Woods__SessionTracer__FileStore_read -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods__SessionTracer -->|deserialization: parse| JSON
  Woods__SessionTracer__RedisStore[\"deserialization"\]
  Woods__SessionTracer__RedisStore -->|deserialization: parse| JSON
  Woods__SessionTracer__RedisStore_read[\"deserialization"\]
  Woods__SessionTracer__RedisStore_read -->|deserialization: parse| JSON
  Woods -->|construction: new| Set
  SessionFlowDocument["SessionFlowDocument"]
  Woods -->|construction: new| SessionFlowDocument
  Woods -->|construction: new| SessionFlowDocument
  Woods__SessionTracer -->|construction: new| Set
  Woods__SessionTracer -->|construction: new| SessionFlowDocument
  Woods__SessionTracer -->|construction: new| SessionFlowDocument
  Woods__SessionTracer__SessionFlowAssembler -->|construction: new| Set
  Woods__SessionTracer__SessionFlowAssembler -->|construction: new| SessionFlowDocument
  Woods__SessionTracer__SessionFlowAssembler -->|construction: new| SessionFlowDocument
  Woods__SessionTracer__SessionFlowAssembler_assemble(["new"])
  Woods__SessionTracer__SessionFlowAssembler_assemble -->|construction: new| Set
  Woods__SessionTracer__SessionFlowAssembler_assemble -->|construction: new| SessionFlowDocument
  Woods__SessionTracer__SessionFlowAssembler_empty_document(["new"])
  Woods__SessionTracer__SessionFlowAssembler_empty_document -->|construction: new| SessionFlowDocument
  Woods__SessionTracer__SessionFlowDocument(["new"])
  Woods__SessionTracer__SessionFlowDocument_from_h(["new"])
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods__SessionTracer -->|deserialization: parse| JSON
  Woods__SessionTracer -->|deserialization: parse| JSON
  Woods__SessionTracer -->|deserialization: parse| JSON
  Woods__SessionTracer__SolidCacheStore[\"deserialization"\]
  Woods__SessionTracer__SolidCacheStore -->|deserialization: parse| JSON
  Woods__SessionTracer__SolidCacheStore -->|deserialization: parse| JSON
  Woods__SessionTracer__SolidCacheStore -->|deserialization: parse| JSON
  Woods__SessionTracer__SolidCacheStore_record[\"deserialization"\]
  Woods__SessionTracer__SolidCacheStore_record -->|deserialization: parse| JSON
  Woods__SessionTracer__SolidCacheStore_read[\"deserialization"\]
  Woods__SessionTracer__SolidCacheStore_read -->|deserialization: parse| JSON
  Woods__SessionTracer__SolidCacheStore_read_index[\"deserialization"\]
  Woods__SessionTracer__SolidCacheStore_read_index -->|deserialization: parse| JSON
  Woods -->|construction: new| DependencyGraph
  Woods__Storage(["new"])
  Woods__Storage -->|construction: new| DependencyGraph
  Woods__Storage__GraphStore(["new"])
  Woods__Storage__GraphStore -->|construction: new| DependencyGraph
  Woods__Storage__GraphStore__Memory(["new"])
  Woods__Storage__GraphStore__Memory -->|construction: new| DependencyGraph
  Woods__Storage__GraphStore__Memory_initialize(["new"])
  Woods__Storage__GraphStore__Memory_initialize -->|construction: new| DependencyGraph
  SQLite3__Database["SQLite3::Database"]
  Woods -->|construction: new| SQLite3__Database
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods__Storage -->|construction: new| SQLite3__Database
  Woods__Storage -->|deserialization: parse| JSON
  Woods__Storage -->|deserialization: parse| JSON
  Woods__Storage -->|deserialization: parse| JSON
  Woods__Storage__MetadataStore(["new"])
  Woods__Storage__MetadataStore -->|construction: new| SQLite3__Database
  Woods__Storage__MetadataStore -->|deserialization: parse| JSON
  Woods__Storage__MetadataStore -->|deserialization: parse| JSON
  Woods__Storage__MetadataStore -->|deserialization: parse| JSON
  Woods__Storage__MetadataStore__SQLite(["new"])
  Woods__Storage__MetadataStore__SQLite -->|construction: new| SQLite3__Database
  Woods__Storage__MetadataStore__SQLite -->|deserialization: parse| JSON
  Woods__Storage__MetadataStore__SQLite -->|deserialization: parse| JSON
  Woods__Storage__MetadataStore__SQLite -->|deserialization: parse| JSON
  Woods__Storage__MetadataStore__SQLite_initialize(["new"])
  Woods__Storage__MetadataStore__SQLite_initialize -->|construction: new| SQLite3__Database
  Woods__Storage__MetadataStore__SQLite_find[\"deserialization"\]
  Woods__Storage__MetadataStore__SQLite_find -->|deserialization: parse| JSON
  Woods__Storage__MetadataStore__SQLite_find_by_type[\"deserialization"\]
  Woods__Storage__MetadataStore__SQLite_find_by_type -->|deserialization: parse| JSON
  Woods__Storage__MetadataStore__SQLite_search[\"deserialization"\]
  Woods__Storage__MetadataStore__SQLite_search -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  SearchResult["SearchResult"]
  Woods -->|construction: new| SearchResult
  Woods__Storage -->|deserialization: parse| JSON
  Woods__Storage -->|construction: new| SearchResult
  Woods__Storage__VectorStore(["parse"])
  Woods__Storage__VectorStore -->|deserialization: parse| JSON
  Woods__Storage__VectorStore -->|construction: new| SearchResult
  Woods__Storage__VectorStore__Pgvector(["parse"])
  Woods__Storage__VectorStore__Pgvector -->|deserialization: parse| JSON
  Woods__Storage__VectorStore__Pgvector -->|construction: new| SearchResult
  Woods__Storage__VectorStore__Pgvector_row_to_result(["parse"])
  Woods__Storage__VectorStore__Pgvector_row_to_result -->|deserialization: parse| JSON
  Woods__Storage__VectorStore__Pgvector_row_to_result -->|construction: new| SearchResult
  Woods -->|construction: new| SearchResult
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| Net__HTTP
  request_class["request_class"]
  Woods -->|construction: new| request_class
  Woods__Storage -->|construction: new| SearchResult
  Woods__Storage -->|deserialization: parse| JSON
  Woods__Storage -->|construction: new| Net__HTTP
  Woods__Storage -->|construction: new| request_class
  Woods__Storage__VectorStore -->|construction: new| SearchResult
  Woods__Storage__VectorStore -->|deserialization: parse| JSON
  Woods__Storage__VectorStore -->|construction: new| Net__HTTP
  Woods__Storage__VectorStore -->|construction: new| request_class
  Woods__Storage__VectorStore__Qdrant(["new"])
  Woods__Storage__VectorStore__Qdrant -->|construction: new| SearchResult
  Woods__Storage__VectorStore__Qdrant -->|deserialization: parse| JSON
  Woods__Storage__VectorStore__Qdrant -->|construction: new| Net__HTTP
  Woods__Storage__VectorStore__Qdrant -->|construction: new| request_class
  Woods__Storage__VectorStore__Qdrant_search(["new"])
  Woods__Storage__VectorStore__Qdrant_search -->|construction: new| SearchResult
  Woods__Storage__VectorStore__Qdrant_request[\"deserialization"\]
  Woods__Storage__VectorStore__Qdrant_request -->|deserialization: parse| JSON
  Woods__Storage__VectorStore__Qdrant_build_http(["new"])
  Woods__Storage__VectorStore__Qdrant_build_http -->|construction: new| Net__HTTP
  Woods__Storage__VectorStore__Qdrant_build_request(["new"])
  Woods__Storage__VectorStore__Qdrant_build_request -->|construction: new| request_class
  Woods -->|construction: new| Struct
  Woods -->|construction: new| SearchResult
  Woods__Storage -->|construction: new| Struct
  Woods__Storage -->|construction: new| SearchResult
  Woods__Storage__VectorStore -->|construction: new| Struct
  Woods__Storage__VectorStore -->|construction: new| SearchResult
  Woods__Storage__VectorStore__InMemory(["new"])
  Woods__Storage__VectorStore__InMemory -->|construction: new| SearchResult
  Woods__Storage__VectorStore__InMemory_search(["new"])
  Woods__Storage__VectorStore__InMemory_search -->|construction: new| SearchResult
```
