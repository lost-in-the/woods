# Data Flow

```mermaid
flowchart TD
  CodebaseIndex(["new"])
  Set["Set"]
  CodebaseIndex -->|construction: new| Set
  CodebaseIndex -->|construction: new| Set
  CodebaseIndex__Ast(["new"])
  CodebaseIndex__Ast -->|construction: new| Set
  CodebaseIndex__Ast -->|construction: new| Set
  CodebaseIndex__Ast__CallSiteExtractor(["new"])
  CodebaseIndex__Ast__CallSiteExtractor -->|construction: new| Set
  CodebaseIndex__Ast__CallSiteExtractor_extract_significant(["new"])
  CodebaseIndex__Ast__CallSiteExtractor_extract_significant -->|construction: new| Set
  Parser["Parser"]
  CodebaseIndex -->|construction: new| Parser
  _parser["@parser"]
  CodebaseIndex -->|deserialization: parse| _parser
  CodebaseIndex -->|deserialization: parse| _parser
  CodebaseIndex__Ast -->|construction: new| Parser
  CodebaseIndex__Ast -->|deserialization: parse| _parser
  CodebaseIndex__Ast -->|deserialization: parse| _parser
  CodebaseIndex__Ast__MethodExtractor(["new"])
  CodebaseIndex__Ast__MethodExtractor -->|construction: new| Parser
  CodebaseIndex__Ast__MethodExtractor -->|deserialization: parse| _parser
  CodebaseIndex__Ast__MethodExtractor -->|deserialization: parse| _parser
  CodebaseIndex__Ast__MethodExtractor_initialize(["new"])
  CodebaseIndex__Ast__MethodExtractor_initialize -->|construction: new| Parser
  CodebaseIndex__Ast__MethodExtractor_extract_method[\"deserialization"\]
  CodebaseIndex__Ast__MethodExtractor_extract_method -->|deserialization: parse| _parser
  CodebaseIndex__Ast__MethodExtractor_extract_all_methods[\"deserialization"\]
  CodebaseIndex__Ast__MethodExtractor_extract_all_methods -->|deserialization: parse| _parser
  Struct["Struct"]
  CodebaseIndex -->|construction: new| Struct
  CodebaseIndex__Ast -->|construction: new| Struct
  Prism["Prism"]
  CodebaseIndex -->|deserialization: parse| Prism
  Parser__Source__Buffer["Parser::Source::Buffer"]
  CodebaseIndex -->|construction: new| Parser__Source__Buffer
  Parser__CurrentRuby["Parser::CurrentRuby"]
  CodebaseIndex -->|deserialization: parse| Parser__CurrentRuby
  Node["Node"]
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex -->|construction: new| Node
  CodebaseIndex__Ast -->|deserialization: parse| Prism
  CodebaseIndex__Ast -->|construction: new| Parser__Source__Buffer
  CodebaseIndex__Ast -->|deserialization: parse| Parser__CurrentRuby
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast -->|construction: new| Node
  CodebaseIndex__Ast__Parser(["parse"])
  CodebaseIndex__Ast__Parser -->|deserialization: parse| Prism
  CodebaseIndex__Ast__Parser -->|construction: new| Parser__Source__Buffer
  CodebaseIndex__Ast__Parser -->|deserialization: parse| Parser__CurrentRuby
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser -->|construction: new| Node
  CodebaseIndex__Ast__Parser_parse_with_prism[\"deserialization"\]
  CodebaseIndex__Ast__Parser_parse_with_prism -->|deserialization: parse| Prism
  CodebaseIndex__Ast__Parser_parse_with_parser_gem(["new"])
  CodebaseIndex__Ast__Parser_parse_with_parser_gem -->|construction: new| Parser__Source__Buffer
  CodebaseIndex__Ast__Parser_parse_with_parser_gem -->|deserialization: parse| Parser__CurrentRuby
  CodebaseIndex__Ast__Parser_convert_prism_node(["new"])
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_class(["new"])
  CodebaseIndex__Ast__Parser_convert_prism_class -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_module(["new"])
  CodebaseIndex__Ast__Parser_convert_prism_module -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_def(["new"])
  CodebaseIndex__Ast__Parser_convert_prism_def -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_call(["new"])
  CodebaseIndex__Ast__Parser_convert_prism_call -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_call -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_call -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_constant_path(["new"])
  CodebaseIndex__Ast__Parser_convert_prism_constant_path -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_if(["new"])
  CodebaseIndex__Ast__Parser_convert_prism_if -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_if -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_unless(["new"])
  CodebaseIndex__Ast__Parser_convert_prism_unless -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_prism_case(["new"])
  CodebaseIndex__Ast__Parser_convert_prism_case -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_parser_node(["new"])
  CodebaseIndex__Ast__Parser_convert_parser_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_parser_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_parser_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_parser_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_parser_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_parser_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_parser_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_parser_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_parser_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_parser_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_parser_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_parser_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_parser_node -->|construction: new| Node
  CodebaseIndex__Ast__Parser_convert_parser_node -->|construction: new| Node
  Configuration["Configuration"]
  CodebaseIndex -->|construction: new| Configuration
  Retriever["Retriever"]
  CodebaseIndex -->|construction: new| Retriever
  Storage__VectorStore__InMemory["Storage::VectorStore::InMemory"]
  CodebaseIndex -->|construction: new| Storage__VectorStore__InMemory
  Storage__VectorStore__Pgvector["Storage::VectorStore::Pgvector"]
  CodebaseIndex -->|construction: new| Storage__VectorStore__Pgvector
  Storage__VectorStore__Qdrant["Storage::VectorStore::Qdrant"]
  CodebaseIndex -->|construction: new| Storage__VectorStore__Qdrant
  Embedding__Provider__OpenAI["Embedding::Provider::OpenAI"]
  CodebaseIndex -->|construction: new| Embedding__Provider__OpenAI
  Embedding__Provider__Ollama["Embedding::Provider::Ollama"]
  CodebaseIndex -->|construction: new| Embedding__Provider__Ollama
  Storage__MetadataStore__InMemory["Storage::MetadataStore::InMemory"]
  CodebaseIndex -->|construction: new| Storage__MetadataStore__InMemory
  Storage__MetadataStore__SQLite["Storage::MetadataStore::SQLite"]
  CodebaseIndex -->|construction: new| Storage__MetadataStore__SQLite
  Storage__GraphStore__Memory["Storage::GraphStore::Memory"]
  CodebaseIndex -->|construction: new| Storage__GraphStore__Memory
  CodebaseIndex__Builder(["new"])
  CodebaseIndex__Builder -->|construction: new| Configuration
  CodebaseIndex__Builder -->|construction: new| Retriever
  CodebaseIndex__Builder -->|construction: new| Storage__VectorStore__InMemory
  CodebaseIndex__Builder -->|construction: new| Storage__VectorStore__Pgvector
  CodebaseIndex__Builder -->|construction: new| Storage__VectorStore__Qdrant
  CodebaseIndex__Builder -->|construction: new| Embedding__Provider__OpenAI
  CodebaseIndex__Builder -->|construction: new| Embedding__Provider__Ollama
  CodebaseIndex__Builder -->|construction: new| Storage__MetadataStore__InMemory
  CodebaseIndex__Builder -->|construction: new| Storage__MetadataStore__SQLite
  CodebaseIndex__Builder -->|construction: new| Storage__GraphStore__Memory
  CodebaseIndex__Builder_preset_config(["new"])
  CodebaseIndex__Builder_preset_config -->|construction: new| Configuration
  CodebaseIndex__Builder_build_retriever(["new"])
  CodebaseIndex__Builder_build_retriever -->|construction: new| Retriever
  CodebaseIndex__Builder_build_vector_store(["new"])
  CodebaseIndex__Builder_build_vector_store -->|construction: new| Storage__VectorStore__InMemory
  CodebaseIndex__Builder_build_vector_store -->|construction: new| Storage__VectorStore__Pgvector
  CodebaseIndex__Builder_build_vector_store -->|construction: new| Storage__VectorStore__Qdrant
  CodebaseIndex__Builder_build_embedding_provider(["new"])
  CodebaseIndex__Builder_build_embedding_provider -->|construction: new| Embedding__Provider__OpenAI
  CodebaseIndex__Builder_build_embedding_provider -->|construction: new| Embedding__Provider__Ollama
  CodebaseIndex__Builder_build_metadata_store(["new"])
  CodebaseIndex__Builder_build_metadata_store -->|construction: new| Storage__MetadataStore__InMemory
  CodebaseIndex__Builder_build_metadata_store -->|construction: new| Storage__MetadataStore__SQLite
  CodebaseIndex__Builder_build_graph_store(["new"])
  CodebaseIndex__Builder_build_graph_store -->|construction: new| Storage__GraphStore__Memory
  ModelChunker["ModelChunker"]
  CodebaseIndex -->|construction: new| ModelChunker
  ControllerChunker["ControllerChunker"]
  CodebaseIndex -->|construction: new| ControllerChunker
  Chunk["Chunk"]
  CodebaseIndex -->|construction: new| Chunk
  CodebaseIndex -->|construction: new| Chunk
  CodebaseIndex -->|construction: new| Chunk
  CodebaseIndex__Chunking(["new"])
  CodebaseIndex__Chunking -->|construction: new| ModelChunker
  CodebaseIndex__Chunking -->|construction: new| ControllerChunker
  CodebaseIndex__Chunking -->|construction: new| Chunk
  CodebaseIndex__Chunking -->|construction: new| Chunk
  CodebaseIndex__Chunking -->|construction: new| Chunk
  CodebaseIndex__Chunking__SemanticChunker(["new"])
  CodebaseIndex__Chunking__SemanticChunker -->|construction: new| ModelChunker
  CodebaseIndex__Chunking__SemanticChunker -->|construction: new| ControllerChunker
  CodebaseIndex__Chunking__SemanticChunker -->|construction: new| Chunk
  CodebaseIndex__Chunking__ModelChunker(["new"])
  CodebaseIndex__Chunking__ModelChunker -->|construction: new| Chunk
  CodebaseIndex__Chunking__ControllerChunker(["new"])
  CodebaseIndex__Chunking__ControllerChunker -->|construction: new| Chunk
  CodebaseIndex__Chunking__SemanticChunker_chunk(["new"])
  CodebaseIndex__Chunking__SemanticChunker_chunk -->|construction: new| ModelChunker
  CodebaseIndex__Chunking__SemanticChunker_chunk -->|construction: new| ControllerChunker
  CodebaseIndex__Chunking__SemanticChunker_build_whole_chunk(["new"])
  CodebaseIndex__Chunking__SemanticChunker_build_whole_chunk -->|construction: new| Chunk
  CodebaseIndex__Chunking__ModelChunker_build_chunk(["new"])
  CodebaseIndex__Chunking__ModelChunker_build_chunk -->|construction: new| Chunk
  CodebaseIndex__Chunking__ControllerChunker_build_chunk(["new"])
  CodebaseIndex__Chunking__ControllerChunker_build_chunk -->|construction: new| Chunk
  JSON["JSON"]
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex__Console[\"deserialization"\]
  CodebaseIndex__Console -->|deserialization: parse| JSON
  CodebaseIndex__Console__AuditLogger[\"deserialization"\]
  CodebaseIndex__Console__AuditLogger -->|deserialization: parse| JSON
  CodebaseIndex__Console__AuditLogger_entries[\"deserialization"\]
  CodebaseIndex__Console__AuditLogger_entries -->|deserialization: parse| JSON
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex__Console -->|deserialization: parse| JSON
  CodebaseIndex__Console__Bridge[\"deserialization"\]
  CodebaseIndex__Console__Bridge -->|deserialization: parse| JSON
  CodebaseIndex__Console__Bridge_parse_request[\"deserialization"\]
  CodebaseIndex__Console__Bridge_parse_request -->|deserialization: parse| JSON
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex__Console -->|deserialization: parse| JSON
  CodebaseIndex__Console__ConnectionManager[\"deserialization"\]
  CodebaseIndex__Console__ConnectionManager -->|deserialization: parse| JSON
  CodebaseIndex__Console__ConnectionManager_send_request[\"deserialization"\]
  CodebaseIndex__Console__ConnectionManager_send_request -->|deserialization: parse| JSON
  ConnectionManager["ConnectionManager"]
  CodebaseIndex -->|construction: new| ConnectionManager
  SafeContext["SafeContext"]
  CodebaseIndex -->|construction: new| SafeContext
  MCP__Server["MCP::Server"]
  CodebaseIndex -->|construction: new| MCP__Server
  MCP__Tool__Response["MCP::Tool::Response"]
  CodebaseIndex -->|construction: new| MCP__Tool__Response
  CodebaseIndex -->|construction: new| MCP__Tool__Response
  CodebaseIndex -->|construction: new| MCP__Tool__Response
  SqlValidator["SqlValidator"]
  CodebaseIndex -->|construction: new| SqlValidator
  CodebaseIndex__Console -->|construction: new| ConnectionManager
  CodebaseIndex__Console -->|construction: new| SafeContext
  CodebaseIndex__Console -->|construction: new| MCP__Server
  CodebaseIndex__Console -->|construction: new| MCP__Tool__Response
  CodebaseIndex__Console -->|construction: new| MCP__Tool__Response
  CodebaseIndex__Console -->|construction: new| MCP__Tool__Response
  CodebaseIndex__Console -->|construction: new| SqlValidator
  CodebaseIndex__Console__Server(["new"])
  CodebaseIndex__Console__Server -->|construction: new| ConnectionManager
  CodebaseIndex__Console__Server -->|construction: new| SafeContext
  CodebaseIndex__Console__Server -->|construction: new| MCP__Server
  CodebaseIndex__Console__Server -->|construction: new| MCP__Tool__Response
  CodebaseIndex__Console__Server -->|construction: new| MCP__Tool__Response
  CodebaseIndex__Console__Server -->|construction: new| MCP__Tool__Response
  CodebaseIndex__Console__Server -->|construction: new| SqlValidator
  EmbeddingCost["EmbeddingCost"]
  CodebaseIndex -->|construction: new| EmbeddingCost
  StorageCost["StorageCost"]
  CodebaseIndex -->|construction: new| StorageCost
  CodebaseIndex__CostModel(["new"])
  CodebaseIndex__CostModel -->|construction: new| EmbeddingCost
  CodebaseIndex__CostModel -->|construction: new| StorageCost
  CodebaseIndex__CostModel__Estimator(["new"])
  CodebaseIndex__CostModel__Estimator -->|construction: new| EmbeddingCost
  CodebaseIndex__CostModel__Estimator -->|construction: new| StorageCost
  CodebaseIndex__CostModel__Estimator_initialize(["new"])
  CodebaseIndex__CostModel__Estimator_initialize -->|construction: new| EmbeddingCost
  CodebaseIndex__CostModel__Estimator_initialize -->|construction: new| StorageCost
  SchemaVersion["SchemaVersion"]
  CodebaseIndex -->|construction: new| SchemaVersion
  CodebaseIndex__Db(["new"])
  CodebaseIndex__Db -->|construction: new| SchemaVersion
  CodebaseIndex__Db__Migrator(["new"])
  CodebaseIndex__Db__Migrator -->|construction: new| SchemaVersion
  CodebaseIndex__Db__Migrator_initialize(["new"])
  CodebaseIndex__Db__Migrator_initialize -->|construction: new| SchemaVersion
  CodebaseIndex -->|construction: new| Set
  affected["affected"]
  CodebaseIndex -->|serialization: to_a| affected
  CodebaseIndex__DependencyGraph(["new"])
  CodebaseIndex__DependencyGraph -->|construction: new| Set
  CodebaseIndex__DependencyGraph -->|serialization: to_a| affected
  CodebaseIndex__DependencyGraph_affected_by(["new"])
  CodebaseIndex__DependencyGraph_affected_by -->|construction: new| Set
  CodebaseIndex__DependencyGraph_affected_by -->|serialization: to_a| affected
  CodebaseIndex__DependencyGraph_from_h(["new"])
  CodebaseIndex -->|deserialization: parse| JSON
  ExtractedUnit["ExtractedUnit"]
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex__Embedding(["parse"])
  CodebaseIndex__Embedding -->|deserialization: parse| JSON
  CodebaseIndex__Embedding -->|construction: new| ExtractedUnit
  CodebaseIndex__Embedding -->|deserialization: parse| JSON
  CodebaseIndex__Embedding__Indexer(["parse"])
  CodebaseIndex__Embedding__Indexer -->|deserialization: parse| JSON
  CodebaseIndex__Embedding__Indexer -->|construction: new| ExtractedUnit
  CodebaseIndex__Embedding__Indexer -->|deserialization: parse| JSON
  CodebaseIndex__Embedding__Indexer_load_units[\"deserialization"\]
  CodebaseIndex__Embedding__Indexer_load_units -->|deserialization: parse| JSON
  CodebaseIndex__Embedding__Indexer_build_unit(["new"])
  CodebaseIndex__Embedding__Indexer_build_unit -->|construction: new| ExtractedUnit
  CodebaseIndex__Embedding__Indexer_load_checkpoint[\"deserialization"\]
  CodebaseIndex__Embedding__Indexer_load_checkpoint -->|deserialization: parse| JSON
  Net__HTTP["Net::HTTP"]
  CodebaseIndex -->|construction: new| Net__HTTP
  Net__HTTP__Post["Net::HTTP::Post"]
  CodebaseIndex -->|construction: new| Net__HTTP__Post
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex__Embedding -->|construction: new| Net__HTTP
  CodebaseIndex__Embedding -->|construction: new| Net__HTTP__Post
  CodebaseIndex__Embedding -->|deserialization: parse| JSON
  CodebaseIndex__Embedding__Provider(["new"])
  CodebaseIndex__Embedding__Provider -->|construction: new| Net__HTTP
  CodebaseIndex__Embedding__Provider -->|construction: new| Net__HTTP__Post
  CodebaseIndex__Embedding__Provider -->|deserialization: parse| JSON
  CodebaseIndex__Embedding__Provider__OpenAI(["new"])
  CodebaseIndex__Embedding__Provider__OpenAI -->|construction: new| Net__HTTP
  CodebaseIndex__Embedding__Provider__OpenAI -->|construction: new| Net__HTTP__Post
  CodebaseIndex__Embedding__Provider__OpenAI -->|deserialization: parse| JSON
  CodebaseIndex__Embedding__Provider__OpenAI_post_request(["new"])
  CodebaseIndex__Embedding__Provider__OpenAI_post_request -->|construction: new| Net__HTTP
  CodebaseIndex__Embedding__Provider__OpenAI_post_request -->|construction: new| Net__HTTP__Post
  CodebaseIndex__Embedding__Provider__OpenAI_post_request -->|deserialization: parse| JSON
  CodebaseIndex -->|construction: new| Net__HTTP
  CodebaseIndex -->|construction: new| Net__HTTP__Post
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex__Embedding -->|construction: new| Net__HTTP
  CodebaseIndex__Embedding -->|construction: new| Net__HTTP__Post
  CodebaseIndex__Embedding -->|deserialization: parse| JSON
  CodebaseIndex__Embedding__Provider -->|construction: new| Net__HTTP
  CodebaseIndex__Embedding__Provider -->|construction: new| Net__HTTP__Post
  CodebaseIndex__Embedding__Provider -->|deserialization: parse| JSON
  CodebaseIndex__Embedding__Provider__Ollama(["new"])
  CodebaseIndex__Embedding__Provider__Ollama -->|construction: new| Net__HTTP
  CodebaseIndex__Embedding__Provider__Ollama -->|construction: new| Net__HTTP__Post
  CodebaseIndex__Embedding__Provider__Ollama -->|deserialization: parse| JSON
  CodebaseIndex__Embedding__Provider__Ollama_post_request(["new"])
  CodebaseIndex__Embedding__Provider__Ollama_post_request -->|construction: new| Net__HTTP
  CodebaseIndex__Embedding__Provider__Ollama_post_request -->|construction: new| Net__HTTP__Post
  CodebaseIndex__Embedding__Provider__Ollama_post_request -->|deserialization: parse| JSON
  CodebaseIndex -->|construction: new| Struct
  CodebaseIndex -->|construction: new| Struct
  EvaluationReport["EvaluationReport"]
  CodebaseIndex -->|construction: new| EvaluationReport
  QueryResult["QueryResult"]
  CodebaseIndex -->|construction: new| QueryResult
  CodebaseIndex__Evaluation(["new"])
  CodebaseIndex__Evaluation -->|construction: new| Struct
  CodebaseIndex__Evaluation -->|construction: new| Struct
  CodebaseIndex__Evaluation -->|construction: new| EvaluationReport
  CodebaseIndex__Evaluation -->|construction: new| QueryResult
  CodebaseIndex__Evaluation__Evaluator(["new"])
  CodebaseIndex__Evaluation__Evaluator -->|construction: new| Struct
  CodebaseIndex__Evaluation__Evaluator -->|construction: new| Struct
  CodebaseIndex__Evaluation__Evaluator -->|construction: new| EvaluationReport
  CodebaseIndex__Evaluation__Evaluator -->|construction: new| QueryResult
  CodebaseIndex__Evaluation__Evaluator_evaluate(["new"])
  CodebaseIndex__Evaluation__Evaluator_evaluate -->|construction: new| EvaluationReport
  CodebaseIndex__Evaluation__Evaluator_evaluate_query(["new"])
  CodebaseIndex__Evaluation__Evaluator_evaluate_query -->|construction: new| QueryResult
  CodebaseIndex -->|construction: new| Struct
  CodebaseIndex -->|deserialization: parse| JSON
  Query["Query"]
  CodebaseIndex -->|construction: new| Query
  CodebaseIndex__Evaluation -->|construction: new| Struct
  CodebaseIndex__Evaluation -->|deserialization: parse| JSON
  CodebaseIndex__Evaluation -->|construction: new| Query
  CodebaseIndex__Evaluation__QuerySet(["new"])
  CodebaseIndex__Evaluation__QuerySet -->|construction: new| Struct
  CodebaseIndex__Evaluation__QuerySet -->|deserialization: parse| JSON
  CodebaseIndex__Evaluation__QuerySet -->|construction: new| Query
  CodebaseIndex__Evaluation__QuerySet_load(["parse"])
  CodebaseIndex__Evaluation__QuerySet_load -->|deserialization: parse| JSON
  CodebaseIndex__Evaluation__QuerySet_parse_query(["new"])
  CodebaseIndex__Evaluation__QuerySet_parse_query -->|construction: new| Query
  metadata["metadata"]
  CodebaseIndex -->|serialization: to_json| metadata
  CodebaseIndex__ExtractedUnit[/"serialization"/]
  CodebaseIndex__ExtractedUnit -->|serialization: to_json| metadata
  CodebaseIndex__ExtractedUnit_estimated_tokens[/"serialization"/]
  CodebaseIndex__ExtractedUnit_estimated_tokens -->|serialization: to_json| metadata
  Pathname["Pathname"]
  CodebaseIndex -->|construction: new| Pathname
  DependencyGraph["DependencyGraph"]
  CodebaseIndex -->|construction: new| DependencyGraph
  GraphAnalyzer["GraphAnalyzer"]
  CodebaseIndex -->|construction: new| GraphAnalyzer
  CodebaseIndex -->|construction: new| Pathname
  CodebaseIndex -->|construction: new| Set
  extractor_class["extractor_class"]
  CodebaseIndex -->|construction: new| extractor_class
  Mutex["Mutex"]
  CodebaseIndex -->|construction: new| Mutex
  Thread["Thread"]
  CodebaseIndex -->|construction: new| Thread
  CodebaseIndex -->|construction: new| extractor_class
  FlowPrecomputer["FlowPrecomputer"]
  CodebaseIndex -->|construction: new| FlowPrecomputer
  Hash["Hash"]
  CodebaseIndex -->|construction: new| Hash
  _dependency_graph["@dependency_graph"]
  CodebaseIndex -->|serialization: to_h| _dependency_graph
  CodebaseIndex -->|serialization: to_h| _dependency_graph
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex -->|serialization: to_h| _dependency_graph
  EXTRACTORS___["EXTRACTORS.[]"]
  CodebaseIndex -->|construction: new| EXTRACTORS___
  CodebaseIndex__Extractor(["new"])
  CodebaseIndex__Extractor -->|construction: new| Pathname
  CodebaseIndex__Extractor -->|construction: new| DependencyGraph
  CodebaseIndex__Extractor -->|construction: new| GraphAnalyzer
  CodebaseIndex__Extractor -->|construction: new| Pathname
  CodebaseIndex__Extractor -->|construction: new| Set
  CodebaseIndex__Extractor -->|construction: new| extractor_class
  CodebaseIndex__Extractor -->|construction: new| Mutex
  CodebaseIndex__Extractor -->|construction: new| Thread
  CodebaseIndex__Extractor -->|construction: new| extractor_class
  CodebaseIndex__Extractor -->|construction: new| FlowPrecomputer
  CodebaseIndex__Extractor -->|construction: new| Hash
  CodebaseIndex__Extractor -->|serialization: to_h| _dependency_graph
  CodebaseIndex__Extractor -->|serialization: to_h| _dependency_graph
  CodebaseIndex__Extractor -->|deserialization: parse| JSON
  CodebaseIndex__Extractor -->|serialization: to_h| _dependency_graph
  CodebaseIndex__Extractor -->|construction: new| EXTRACTORS___
  CodebaseIndex__Extractor_initialize(["new"])
  CodebaseIndex__Extractor_initialize -->|construction: new| Pathname
  CodebaseIndex__Extractor_initialize -->|construction: new| DependencyGraph
  CodebaseIndex__Extractor_extract_all(["new"])
  CodebaseIndex__Extractor_extract_all -->|construction: new| GraphAnalyzer
  CodebaseIndex__Extractor_extract_changed(["new"])
  CodebaseIndex__Extractor_extract_changed -->|construction: new| Pathname
  CodebaseIndex__Extractor_extract_changed -->|construction: new| Set
  CodebaseIndex__Extractor_extract_all_sequential(["new"])
  CodebaseIndex__Extractor_extract_all_sequential -->|construction: new| extractor_class
  CodebaseIndex__Extractor_extract_all_concurrent(["new"])
  CodebaseIndex__Extractor_extract_all_concurrent -->|construction: new| Mutex
  CodebaseIndex__Extractor_extract_all_concurrent -->|construction: new| Thread
  CodebaseIndex__Extractor_extract_all_concurrent -->|construction: new| extractor_class
  CodebaseIndex__Extractor_precompute_flows(["new"])
  CodebaseIndex__Extractor_precompute_flows -->|construction: new| FlowPrecomputer
  CodebaseIndex__Extractor_parse_git_log_output(["new"])
  CodebaseIndex__Extractor_parse_git_log_output -->|construction: new| Hash
  CodebaseIndex__Extractor_write_dependency_graph[/"serialization"/]
  CodebaseIndex__Extractor_write_dependency_graph -->|serialization: to_h| _dependency_graph
  CodebaseIndex__Extractor_write_structural_summary[/"serialization"/]
  CodebaseIndex__Extractor_write_structural_summary -->|serialization: to_h| _dependency_graph
  CodebaseIndex__Extractor_regenerate_type_index[\"deserialization"\]
  CodebaseIndex__Extractor_regenerate_type_index -->|deserialization: parse| JSON
  CodebaseIndex__Extractor_re_extract_unit(["to_h"])
  CodebaseIndex__Extractor_re_extract_unit -->|serialization: to_h| _dependency_graph
  CodebaseIndex__Extractor_re_extract_unit -->|construction: new| EXTRACTORS___
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors(["new"])
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ActionCableExtractor(["new"])
  CodebaseIndex__Extractors__ActionCableExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ActionCableExtractor_extract_channel(["new"])
  CodebaseIndex__Extractors__ActionCableExtractor_extract_channel -->|construction: new| ExtractedUnit
  Ast__MethodExtractor["Ast::MethodExtractor"]
  CodebaseIndex -->|construction: new| Ast__MethodExtractor
  CodebaseIndex__Extractors -->|construction: new| Ast__MethodExtractor
  CodebaseIndex__Extractors__AstSourceExtraction(["new"])
  CodebaseIndex__Extractors__AstSourceExtraction -->|construction: new| Ast__MethodExtractor
  CodebaseIndex__Extractors__AstSourceExtraction_extract_action_source(["new"])
  CodebaseIndex__Extractors__AstSourceExtraction_extract_action_source -->|construction: new| Ast__MethodExtractor
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__BehavioralProfile(["new"])
  CodebaseIndex__Extractors__BehavioralProfile -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__BehavioralProfile_build_unit(["new"])
  CodebaseIndex__Extractors__BehavioralProfile_build_unit -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__CachingExtractor(["new"])
  CodebaseIndex__Extractors__CachingExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__CachingExtractor_extract_caching_file(["new"])
  CodebaseIndex__Extractors__CachingExtractor_extract_caching_file -->|construction: new| ExtractedUnit
  Ast__Parser["Ast::Parser"]
  CodebaseIndex -->|construction: new| Ast__Parser
  FlowAnalysis__OperationExtractor["FlowAnalysis::OperationExtractor"]
  CodebaseIndex -->|construction: new| FlowAnalysis__OperationExtractor
  CodebaseIndex -->|deserialization: parse| _parser
  CodebaseIndex -->|construction: new| Set
  columns["columns"]
  CodebaseIndex -->|serialization: to_a| columns
  CodebaseIndex__Extractors -->|construction: new| Ast__Parser
  CodebaseIndex__Extractors -->|construction: new| FlowAnalysis__OperationExtractor
  CodebaseIndex__Extractors -->|deserialization: parse| _parser
  CodebaseIndex__Extractors -->|construction: new| Set
  CodebaseIndex__Extractors -->|serialization: to_a| columns
  CodebaseIndex__Extractors__CallbackAnalyzer(["new"])
  CodebaseIndex__Extractors__CallbackAnalyzer -->|construction: new| Ast__Parser
  CodebaseIndex__Extractors__CallbackAnalyzer -->|construction: new| FlowAnalysis__OperationExtractor
  CodebaseIndex__Extractors__CallbackAnalyzer -->|deserialization: parse| _parser
  CodebaseIndex__Extractors__CallbackAnalyzer -->|construction: new| Set
  CodebaseIndex__Extractors__CallbackAnalyzer -->|serialization: to_a| columns
  CodebaseIndex__Extractors__CallbackAnalyzer_initialize(["new"])
  CodebaseIndex__Extractors__CallbackAnalyzer_initialize -->|construction: new| Ast__Parser
  CodebaseIndex__Extractors__CallbackAnalyzer_initialize -->|construction: new| FlowAnalysis__OperationExtractor
  CodebaseIndex__Extractors__CallbackAnalyzer_safe_parse[\"deserialization"\]
  CodebaseIndex__Extractors__CallbackAnalyzer_safe_parse -->|deserialization: parse| _parser
  CodebaseIndex__Extractors__CallbackAnalyzer_detect_columns_written(["new"])
  CodebaseIndex__Extractors__CallbackAnalyzer_detect_columns_written -->|construction: new| Set
  CodebaseIndex__Extractors__CallbackAnalyzer_detect_columns_written -->|serialization: to_a| columns
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ConcernExtractor(["new"])
  CodebaseIndex__Extractors__ConcernExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ConcernExtractor_extract_concern_file(["new"])
  CodebaseIndex__Extractors__ConcernExtractor_extract_concern_file -->|construction: new| ExtractedUnit
  BehavioralProfile["BehavioralProfile"]
  CodebaseIndex -->|construction: new| BehavioralProfile
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| BehavioralProfile
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ConfigurationExtractor(["new"])
  CodebaseIndex__Extractors__ConfigurationExtractor -->|construction: new| BehavioralProfile
  CodebaseIndex__Extractors__ConfigurationExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ConfigurationExtractor_extract_all(["new"])
  CodebaseIndex__Extractors__ConfigurationExtractor_extract_all -->|construction: new| BehavioralProfile
  CodebaseIndex__Extractors__ConfigurationExtractor_extract_configuration_file(["new"])
  CodebaseIndex__Extractors__ConfigurationExtractor_extract_configuration_file -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  actions["actions"]
  CodebaseIndex -->|serialization: to_a| actions
  controller_action_methods["controller.action_methods"]
  CodebaseIndex -->|serialization: to_a| controller_action_methods
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|serialization: to_a| actions
  CodebaseIndex__Extractors -->|serialization: to_a| controller_action_methods
  CodebaseIndex__Extractors__ControllerExtractor(["new"])
  CodebaseIndex__Extractors__ControllerExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ControllerExtractor -->|serialization: to_a| actions
  CodebaseIndex__Extractors__ControllerExtractor -->|serialization: to_a| controller_action_methods
  CodebaseIndex__Extractors__ControllerExtractor_extract_controller(["new"])
  CodebaseIndex__Extractors__ControllerExtractor_extract_controller -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ControllerExtractor_extract_action_filter_actions[/"serialization"/]
  CodebaseIndex__Extractors__ControllerExtractor_extract_action_filter_actions -->|serialization: to_a| actions
  CodebaseIndex__Extractors__ControllerExtractor_extract_metadata[/"serialization"/]
  CodebaseIndex__Extractors__ControllerExtractor_extract_metadata -->|serialization: to_a| controller_action_methods
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__DatabaseViewExtractor(["new"])
  CodebaseIndex__Extractors__DatabaseViewExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__DatabaseViewExtractor_extract_view_file(["new"])
  CodebaseIndex__Extractors__DatabaseViewExtractor_extract_view_file -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__DecoratorExtractor(["new"])
  CodebaseIndex__Extractors__DecoratorExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__DecoratorExtractor_extract_decorator_file(["new"])
  CodebaseIndex__Extractors__DecoratorExtractor_extract_decorator_file -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| Set
  controllers["controllers"]
  CodebaseIndex -->|serialization: to_a| controllers
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| Set
  CodebaseIndex__Extractors -->|serialization: to_a| controllers
  CodebaseIndex__Extractors__EngineExtractor(["new"])
  CodebaseIndex__Extractors__EngineExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__EngineExtractor -->|construction: new| Set
  CodebaseIndex__Extractors__EngineExtractor -->|serialization: to_a| controllers
  CodebaseIndex__Extractors__EngineExtractor_extract_engine(["new"])
  CodebaseIndex__Extractors__EngineExtractor_extract_engine -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__EngineExtractor_extract_engine_controllers(["new"])
  CodebaseIndex__Extractors__EngineExtractor_extract_engine_controllers -->|construction: new| Set
  CodebaseIndex__Extractors__EngineExtractor_extract_engine_controllers -->|serialization: to_a| controllers
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__EventExtractor(["new"])
  CodebaseIndex__Extractors__EventExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__EventExtractor_build_unit(["new"])
  CodebaseIndex__Extractors__EventExtractor_build_unit -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__FactoryExtractor(["new"])
  CodebaseIndex__Extractors__FactoryExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__FactoryExtractor_build_unit(["new"])
  CodebaseIndex__Extractors__FactoryExtractor_build_unit -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| Set
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| Set
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__GraphQLExtractor(["new"])
  CodebaseIndex__Extractors__GraphQLExtractor -->|construction: new| Set
  CodebaseIndex__Extractors__GraphQLExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__GraphQLExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__GraphQLExtractor_extract_all(["new"])
  CodebaseIndex__Extractors__GraphQLExtractor_extract_all -->|construction: new| Set
  CodebaseIndex__Extractors__GraphQLExtractor_extract_graphql_file(["new"])
  CodebaseIndex__Extractors__GraphQLExtractor_extract_graphql_file -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__GraphQLExtractor_extract_from_runtime_type(["new"])
  CodebaseIndex__Extractors__GraphQLExtractor_extract_from_runtime_type -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__I18nExtractor(["new"])
  CodebaseIndex__Extractors__I18nExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__I18nExtractor_extract_i18n_file(["new"])
  CodebaseIndex__Extractors__I18nExtractor_extract_i18n_file -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__JobExtractor(["new"])
  CodebaseIndex__Extractors__JobExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__JobExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__JobExtractor_extract_job_file(["new"])
  CodebaseIndex__Extractors__JobExtractor_extract_job_file -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__JobExtractor_extract_job_class(["new"])
  CodebaseIndex__Extractors__JobExtractor_extract_job_class -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  mailer_action_methods["mailer.action_methods"]
  CodebaseIndex -->|serialization: to_a| mailer_action_methods
  CodebaseIndex -->|serialization: to_a| mailer_action_methods
  CodebaseIndex -->|serialization: to_a| actions
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|serialization: to_a| mailer_action_methods
  CodebaseIndex__Extractors -->|serialization: to_a| mailer_action_methods
  CodebaseIndex__Extractors -->|serialization: to_a| actions
  CodebaseIndex__Extractors__MailerExtractor(["new"])
  CodebaseIndex__Extractors__MailerExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__MailerExtractor -->|serialization: to_a| mailer_action_methods
  CodebaseIndex__Extractors__MailerExtractor -->|serialization: to_a| mailer_action_methods
  CodebaseIndex__Extractors__MailerExtractor -->|serialization: to_a| actions
  CodebaseIndex__Extractors__MailerExtractor_extract_mailer(["new"])
  CodebaseIndex__Extractors__MailerExtractor_extract_mailer -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__MailerExtractor_annotate_source[/"serialization"/]
  CodebaseIndex__Extractors__MailerExtractor_annotate_source -->|serialization: to_a| mailer_action_methods
  CodebaseIndex__Extractors__MailerExtractor_extract_metadata[/"serialization"/]
  CodebaseIndex__Extractors__MailerExtractor_extract_metadata -->|serialization: to_a| mailer_action_methods
  CodebaseIndex__Extractors__MailerExtractor_extract_action_filter_actions[/"serialization"/]
  CodebaseIndex__Extractors__MailerExtractor_extract_action_filter_actions -->|serialization: to_a| actions
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ManagerExtractor(["new"])
  CodebaseIndex__Extractors__ManagerExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ManagerExtractor_extract_manager_file(["new"])
  CodebaseIndex__Extractors__ManagerExtractor_extract_manager_file -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__MiddlewareExtractor(["new"])
  CodebaseIndex__Extractors__MiddlewareExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__MiddlewareExtractor_extract_all(["new"])
  CodebaseIndex__Extractors__MiddlewareExtractor_extract_all -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| Hash
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| Hash
  CodebaseIndex__Extractors__MigrationExtractor(["new"])
  CodebaseIndex__Extractors__MigrationExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__MigrationExtractor -->|construction: new| Hash
  CodebaseIndex__Extractors__MigrationExtractor_extract_migration_file(["new"])
  CodebaseIndex__Extractors__MigrationExtractor_extract_migration_file -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__MigrationExtractor_extract_operations(["new"])
  CodebaseIndex__Extractors__MigrationExtractor_extract_operations -->|construction: new| Hash
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| Ast__Parser
  parser["parser"]
  CodebaseIndex -->|deserialization: parse| parser
  CallbackAnalyzer["CallbackAnalyzer"]
  CodebaseIndex -->|construction: new| CallbackAnalyzer
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| Ast__Parser
  CodebaseIndex__Extractors -->|deserialization: parse| parser
  CodebaseIndex__Extractors -->|construction: new| CallbackAnalyzer
  CodebaseIndex__Extractors__ModelExtractor(["new"])
  CodebaseIndex__Extractors__ModelExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ModelExtractor -->|construction: new| Ast__Parser
  CodebaseIndex__Extractors__ModelExtractor -->|deserialization: parse| parser
  CodebaseIndex__Extractors__ModelExtractor -->|construction: new| CallbackAnalyzer
  CodebaseIndex__Extractors__ModelExtractor_extract_model(["new"])
  CodebaseIndex__Extractors__ModelExtractor_extract_model -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ModelExtractor_extract_scopes(["new"])
  CodebaseIndex__Extractors__ModelExtractor_extract_scopes -->|construction: new| Ast__Parser
  CodebaseIndex__Extractors__ModelExtractor_extract_scopes -->|deserialization: parse| parser
  CodebaseIndex__Extractors__ModelExtractor_enrich_callbacks_with_side_effects(["new"])
  CodebaseIndex__Extractors__ModelExtractor_enrich_callbacks_with_side_effects -->|construction: new| CallbackAnalyzer
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__PhlexExtractor(["new"])
  CodebaseIndex__Extractors__PhlexExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__PhlexExtractor_extract_component(["new"])
  CodebaseIndex__Extractors__PhlexExtractor_extract_component -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__PolicyExtractor(["new"])
  CodebaseIndex__Extractors__PolicyExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__PolicyExtractor_extract_policy_file(["new"])
  CodebaseIndex__Extractors__PolicyExtractor_extract_policy_file -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__PunditExtractor(["new"])
  CodebaseIndex__Extractors__PunditExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__PunditExtractor_extract_pundit_file(["new"])
  CodebaseIndex__Extractors__PunditExtractor_extract_pundit_file -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| Pathname
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| Pathname
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__RailsSourceExtractor(["new"])
  CodebaseIndex__Extractors__RailsSourceExtractor -->|construction: new| Pathname
  CodebaseIndex__Extractors__RailsSourceExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__RailsSourceExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__RailsSourceExtractor_find_gem_path(["new"])
  CodebaseIndex__Extractors__RailsSourceExtractor_find_gem_path -->|construction: new| Pathname
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_framework_file(["new"])
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_framework_file -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_gem_file(["new"])
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_gem_file -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__RakeTaskExtractor(["new"])
  CodebaseIndex__Extractors__RakeTaskExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__RakeTaskExtractor_build_unit(["new"])
  CodebaseIndex__Extractors__RakeTaskExtractor_build_unit -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__RouteExtractor(["new"])
  CodebaseIndex__Extractors__RouteExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__RouteExtractor_extract_route(["new"])
  CodebaseIndex__Extractors__RouteExtractor_extract_route -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ScheduledJobExtractor(["new"])
  CodebaseIndex__Extractors__ScheduledJobExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ScheduledJobExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ScheduledJobExtractor_build_yaml_unit(["new"])
  CodebaseIndex__Extractors__ScheduledJobExtractor_build_yaml_unit -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ScheduledJobExtractor_build_whenever_unit(["new"])
  CodebaseIndex__Extractors__ScheduledJobExtractor_build_whenever_unit -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__SerializerExtractor(["new"])
  CodebaseIndex__Extractors__SerializerExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__SerializerExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__SerializerExtractor_extract_serializer_file(["new"])
  CodebaseIndex__Extractors__SerializerExtractor_extract_serializer_file -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__SerializerExtractor_extract_serializer_class(["new"])
  CodebaseIndex__Extractors__SerializerExtractor_extract_serializer_class -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ServiceExtractor(["new"])
  CodebaseIndex__Extractors__ServiceExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ServiceExtractor_extract_service_file(["new"])
  CodebaseIndex__Extractors__ServiceExtractor_extract_service_file -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__StateMachineExtractor(["new"])
  CodebaseIndex__Extractors__StateMachineExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__StateMachineExtractor_build_unit(["new"])
  CodebaseIndex__Extractors__StateMachineExtractor_build_unit -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__TestMappingExtractor(["new"])
  CodebaseIndex__Extractors__TestMappingExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__TestMappingExtractor_extract_test_file(["new"])
  CodebaseIndex__Extractors__TestMappingExtractor_extract_test_file -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ValidatorExtractor(["new"])
  CodebaseIndex__Extractors__ValidatorExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ValidatorExtractor_extract_validator_file(["new"])
  CodebaseIndex__Extractors__ValidatorExtractor_extract_validator_file -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ViewComponentExtractor(["new"])
  CodebaseIndex__Extractors__ViewComponentExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ViewComponentExtractor_extract_component(["new"])
  CodebaseIndex__Extractors__ViewComponentExtractor_extract_component -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| Set
  partials["partials"]
  CodebaseIndex -->|serialization: to_a| partials
  CodebaseIndex -->|construction: new| Set
  found["found"]
  CodebaseIndex -->|serialization: to_a| found
  CodebaseIndex__Extractors -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors -->|construction: new| Set
  CodebaseIndex__Extractors -->|serialization: to_a| partials
  CodebaseIndex__Extractors -->|construction: new| Set
  CodebaseIndex__Extractors -->|serialization: to_a| found
  CodebaseIndex__Extractors__ViewTemplateExtractor(["new"])
  CodebaseIndex__Extractors__ViewTemplateExtractor -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ViewTemplateExtractor -->|construction: new| Set
  CodebaseIndex__Extractors__ViewTemplateExtractor -->|serialization: to_a| partials
  CodebaseIndex__Extractors__ViewTemplateExtractor -->|construction: new| Set
  CodebaseIndex__Extractors__ViewTemplateExtractor -->|serialization: to_a| found
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_view_template_file(["new"])
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_view_template_file -->|construction: new| ExtractedUnit
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_rendered_partials(["new"])
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_rendered_partials -->|construction: new| Set
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_rendered_partials -->|serialization: to_a| partials
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_helpers(["new"])
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_helpers -->|construction: new| Set
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_helpers -->|serialization: to_a| found
  CodebaseIndex -->|construction: new| Hash
  CodebaseIndex -->|construction: new| Hash
  CodebaseIndex__Feedback(["new"])
  CodebaseIndex__Feedback -->|construction: new| Hash
  CodebaseIndex__Feedback -->|construction: new| Hash
  CodebaseIndex__Feedback__GapDetector(["new"])
  CodebaseIndex__Feedback__GapDetector -->|construction: new| Hash
  CodebaseIndex__Feedback__GapDetector -->|construction: new| Hash
  CodebaseIndex__Feedback__GapDetector_count_keywords(["new"])
  CodebaseIndex__Feedback__GapDetector_count_keywords -->|construction: new| Hash
  CodebaseIndex__Feedback__GapDetector_detect_frequently_missing(["new"])
  CodebaseIndex__Feedback__GapDetector_detect_frequently_missing -->|construction: new| Hash
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex__Feedback -->|deserialization: parse| JSON
  CodebaseIndex__Feedback__Store[\"deserialization"\]
  CodebaseIndex__Feedback__Store -->|deserialization: parse| JSON
  CodebaseIndex__Feedback__Store_all_entries[\"deserialization"\]
  CodebaseIndex__Feedback__Store_all_entries -->|deserialization: parse| JSON
  CodebaseIndex -->|construction: new| Ast__Parser
  CodebaseIndex -->|construction: new| Ast__MethodExtractor
  CodebaseIndex -->|construction: new| FlowAnalysis__OperationExtractor
  CodebaseIndex -->|construction: new| Set
  FlowDocument["FlowDocument"]
  CodebaseIndex -->|construction: new| FlowDocument
  CodebaseIndex -->|deserialization: parse| _parser
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex__FlowAssembler(["new"])
  CodebaseIndex__FlowAssembler -->|construction: new| Ast__Parser
  CodebaseIndex__FlowAssembler -->|construction: new| Ast__MethodExtractor
  CodebaseIndex__FlowAssembler -->|construction: new| FlowAnalysis__OperationExtractor
  CodebaseIndex__FlowAssembler -->|construction: new| Set
  CodebaseIndex__FlowAssembler -->|construction: new| FlowDocument
  CodebaseIndex__FlowAssembler -->|deserialization: parse| _parser
  CodebaseIndex__FlowAssembler -->|deserialization: parse| JSON
  CodebaseIndex__FlowAssembler_initialize(["new"])
  CodebaseIndex__FlowAssembler_initialize -->|construction: new| Ast__Parser
  CodebaseIndex__FlowAssembler_initialize -->|construction: new| Ast__MethodExtractor
  CodebaseIndex__FlowAssembler_initialize -->|construction: new| FlowAnalysis__OperationExtractor
  CodebaseIndex__FlowAssembler_assemble(["new"])
  CodebaseIndex__FlowAssembler_assemble -->|construction: new| Set
  CodebaseIndex__FlowAssembler_assemble -->|construction: new| FlowDocument
  CodebaseIndex__FlowAssembler_extract_operations[\"deserialization"\]
  CodebaseIndex__FlowAssembler_extract_operations -->|deserialization: parse| _parser
  CodebaseIndex__FlowAssembler_load_unit[\"deserialization"\]
  CodebaseIndex__FlowAssembler_load_unit -->|deserialization: parse| JSON
  CodebaseIndex__FlowDocument(["new"])
  CodebaseIndex__FlowDocument_from_h(["new"])
  FlowAssembler["FlowAssembler"]
  CodebaseIndex -->|construction: new| FlowAssembler
  CodebaseIndex__FlowPrecomputer(["new"])
  CodebaseIndex__FlowPrecomputer -->|construction: new| FlowAssembler
  CodebaseIndex__FlowPrecomputer_precompute(["new"])
  CodebaseIndex__FlowPrecomputer_precompute -->|construction: new| FlowAssembler
  CodebaseIndex -->|construction: new| Hash
  Random["Random"]
  CodebaseIndex -->|construction: new| Random
  _graph["@graph"]
  CodebaseIndex -->|serialization: to_h| _graph
  CodebaseIndex -->|construction: new| Hash
  CodebaseIndex -->|construction: new| Set
  CodebaseIndex -->|construction: new| Set
  pairs["pairs"]
  CodebaseIndex -->|serialization: to_a| pairs
  CodebaseIndex -->|construction: new| Set
  CodebaseIndex__GraphAnalyzer(["new"])
  CodebaseIndex__GraphAnalyzer -->|construction: new| Hash
  CodebaseIndex__GraphAnalyzer -->|construction: new| Random
  CodebaseIndex__GraphAnalyzer -->|serialization: to_h| _graph
  CodebaseIndex__GraphAnalyzer -->|construction: new| Hash
  CodebaseIndex__GraphAnalyzer -->|construction: new| Set
  CodebaseIndex__GraphAnalyzer -->|construction: new| Set
  CodebaseIndex__GraphAnalyzer -->|serialization: to_a| pairs
  CodebaseIndex__GraphAnalyzer -->|construction: new| Set
  CodebaseIndex__GraphAnalyzer_bridges(["new"])
  CodebaseIndex__GraphAnalyzer_bridges -->|construction: new| Hash
  CodebaseIndex__GraphAnalyzer_bridges -->|construction: new| Random
  CodebaseIndex__GraphAnalyzer_graph_data[/"serialization"/]
  CodebaseIndex__GraphAnalyzer_graph_data -->|serialization: to_h| _graph
  CodebaseIndex__GraphAnalyzer_detect_cycles(["new"])
  CodebaseIndex__GraphAnalyzer_detect_cycles -->|construction: new| Hash
  CodebaseIndex__GraphAnalyzer_detect_cycles -->|construction: new| Set
  CodebaseIndex__GraphAnalyzer_generate_sample_pairs(["new"])
  CodebaseIndex__GraphAnalyzer_generate_sample_pairs -->|construction: new| Set
  CodebaseIndex__GraphAnalyzer_generate_sample_pairs -->|serialization: to_a| pairs
  CodebaseIndex__GraphAnalyzer_bfs_shortest_path(["new"])
  CodebaseIndex__GraphAnalyzer_bfs_shortest_path -->|construction: new| Set
  CodebaseIndex -->|construction: new| Pathname
  Regexp["Regexp"]
  CodebaseIndex -->|construction: new| Regexp
  CodebaseIndex -->|construction: new| Regexp
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex -->|construction: new| Set
  CodebaseIndex__MCP(["new"])
  CodebaseIndex__MCP -->|construction: new| Pathname
  CodebaseIndex__MCP -->|construction: new| Regexp
  CodebaseIndex__MCP -->|construction: new| Regexp
  CodebaseIndex__MCP -->|deserialization: parse| JSON
  CodebaseIndex__MCP -->|deserialization: parse| JSON
  CodebaseIndex__MCP -->|deserialization: parse| JSON
  CodebaseIndex__MCP -->|construction: new| Set
  CodebaseIndex__MCP__IndexReader(["new"])
  CodebaseIndex__MCP__IndexReader -->|construction: new| Pathname
  CodebaseIndex__MCP__IndexReader -->|construction: new| Regexp
  CodebaseIndex__MCP__IndexReader -->|construction: new| Regexp
  CodebaseIndex__MCP__IndexReader -->|deserialization: parse| JSON
  CodebaseIndex__MCP__IndexReader -->|deserialization: parse| JSON
  CodebaseIndex__MCP__IndexReader -->|deserialization: parse| JSON
  CodebaseIndex__MCP__IndexReader -->|construction: new| Set
  CodebaseIndex__MCP__IndexReader_initialize(["new"])
  CodebaseIndex__MCP__IndexReader_initialize -->|construction: new| Pathname
  CodebaseIndex__MCP__IndexReader_search(["new"])
  CodebaseIndex__MCP__IndexReader_search -->|construction: new| Regexp
  CodebaseIndex__MCP__IndexReader_framework_sources(["new"])
  CodebaseIndex__MCP__IndexReader_framework_sources -->|construction: new| Regexp
  CodebaseIndex__MCP__IndexReader_read_index[\"deserialization"\]
  CodebaseIndex__MCP__IndexReader_read_index -->|deserialization: parse| JSON
  CodebaseIndex__MCP__IndexReader_load_unit[\"deserialization"\]
  CodebaseIndex__MCP__IndexReader_load_unit -->|deserialization: parse| JSON
  CodebaseIndex__MCP__IndexReader_parse_json[\"deserialization"\]
  CodebaseIndex__MCP__IndexReader_parse_json -->|deserialization: parse| JSON
  CodebaseIndex__MCP__IndexReader_traverse(["new"])
  CodebaseIndex__MCP__IndexReader_traverse -->|construction: new| Set
  IndexReader["IndexReader"]
  CodebaseIndex -->|construction: new| IndexReader
  CodebaseIndex -->|construction: new| MCP__Server
  CodebaseIndex -->|construction: new| MCP__Tool__Response
  CodebaseIndex -->|construction: new| CodebaseIndex__FlowAssembler
  CodebaseIndex__SessionTracer__SessionFlowAssembler["CodebaseIndex::SessionTracer::SessionFlowAssembler"]
  CodebaseIndex -->|construction: new| CodebaseIndex__SessionTracer__SessionFlowAssembler
  CodebaseIndex -->|construction: new| Thread
  CodebaseIndex -->|construction: new| CodebaseIndex__Extractor
  Logger["Logger"]
  CodebaseIndex -->|construction: new| Logger
  CodebaseIndex -->|construction: new| Thread
  CodebaseIndex -->|construction: new| CodebaseIndex__Builder
  CodebaseIndex__Embedding__TextPreparer["CodebaseIndex::Embedding::TextPreparer"]
  CodebaseIndex -->|construction: new| CodebaseIndex__Embedding__TextPreparer
  CodebaseIndex -->|construction: new| CodebaseIndex__Embedding__Indexer
  CodebaseIndex -->|construction: new| Logger
  StandardError["StandardError"]
  CodebaseIndex -->|construction: new| StandardError
  CodebaseIndex -->|construction: new| CodebaseIndex__Feedback__GapDetector
  MCP__ResourceTemplate["MCP::ResourceTemplate"]
  CodebaseIndex -->|construction: new| MCP__ResourceTemplate
  CodebaseIndex -->|construction: new| MCP__ResourceTemplate
  MCP__Resource["MCP::Resource"]
  CodebaseIndex -->|construction: new| MCP__Resource
  CodebaseIndex -->|construction: new| MCP__Resource
  CodebaseIndex__MCP -->|construction: new| IndexReader
  CodebaseIndex__MCP -->|construction: new| MCP__Server
  CodebaseIndex__MCP -->|construction: new| MCP__Tool__Response
  CodebaseIndex__MCP -->|construction: new| CodebaseIndex__FlowAssembler
  CodebaseIndex__MCP -->|construction: new| CodebaseIndex__SessionTracer__SessionFlowAssembler
  CodebaseIndex__MCP -->|construction: new| Thread
  CodebaseIndex__MCP -->|construction: new| CodebaseIndex__Extractor
  CodebaseIndex__MCP -->|construction: new| Logger
  CodebaseIndex__MCP -->|construction: new| Thread
  CodebaseIndex__MCP -->|construction: new| CodebaseIndex__Builder
  CodebaseIndex__MCP -->|construction: new| CodebaseIndex__Embedding__TextPreparer
  CodebaseIndex__MCP -->|construction: new| CodebaseIndex__Embedding__Indexer
  CodebaseIndex__MCP -->|construction: new| Logger
  CodebaseIndex__MCP -->|construction: new| StandardError
  CodebaseIndex__MCP -->|construction: new| CodebaseIndex__Feedback__GapDetector
  CodebaseIndex__MCP -->|construction: new| MCP__ResourceTemplate
  CodebaseIndex__MCP -->|construction: new| MCP__ResourceTemplate
  CodebaseIndex__MCP -->|construction: new| MCP__Resource
  CodebaseIndex__MCP -->|construction: new| MCP__Resource
  CodebaseIndex__MCP__Server(["new"])
  CodebaseIndex__MCP__Server -->|construction: new| IndexReader
  CodebaseIndex__MCP__Server -->|construction: new| MCP__Server
  CodebaseIndex__MCP__Server -->|construction: new| MCP__Tool__Response
  CodebaseIndex__MCP__Server -->|construction: new| CodebaseIndex__FlowAssembler
  CodebaseIndex__MCP__Server -->|construction: new| CodebaseIndex__SessionTracer__SessionFlowAssembler
  CodebaseIndex__MCP__Server -->|construction: new| Thread
  CodebaseIndex__MCP__Server -->|construction: new| CodebaseIndex__Extractor
  CodebaseIndex__MCP__Server -->|construction: new| Logger
  CodebaseIndex__MCP__Server -->|construction: new| Thread
  CodebaseIndex__MCP__Server -->|construction: new| CodebaseIndex__Builder
  CodebaseIndex__MCP__Server -->|construction: new| CodebaseIndex__Embedding__TextPreparer
  CodebaseIndex__MCP__Server -->|construction: new| CodebaseIndex__Embedding__Indexer
  CodebaseIndex__MCP__Server -->|construction: new| Logger
  CodebaseIndex__MCP__Server -->|construction: new| StandardError
  CodebaseIndex__MCP__Server -->|construction: new| CodebaseIndex__Feedback__GapDetector
  CodebaseIndex__MCP__Server -->|construction: new| MCP__ResourceTemplate
  CodebaseIndex__MCP__Server -->|construction: new| MCP__ResourceTemplate
  CodebaseIndex__MCP__Server -->|construction: new| MCP__Resource
  CodebaseIndex__MCP__Server -->|construction: new| MCP__Resource
  CodebaseIndex -->|construction: new| Struct
  HealthStatus["HealthStatus"]
  CodebaseIndex -->|construction: new| HealthStatus
  CodebaseIndex__Observability(["new"])
  CodebaseIndex__Observability -->|construction: new| Struct
  CodebaseIndex__Observability -->|construction: new| HealthStatus
  CodebaseIndex__Observability__HealthCheck(["new"])
  CodebaseIndex__Observability__HealthCheck -->|construction: new| Struct
  CodebaseIndex__Observability__HealthCheck -->|construction: new| HealthStatus
  CodebaseIndex__Observability__HealthCheck_run(["new"])
  CodebaseIndex__Observability__HealthCheck_run -->|construction: new| HealthStatus
  CodebaseIndex -->|deserialization: parse| JSON
  Time["Time"]
  CodebaseIndex -->|deserialization: parse| Time
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex__Operator[\"deserialization"\]
  CodebaseIndex__Operator -->|deserialization: parse| JSON
  CodebaseIndex__Operator -->|deserialization: parse| Time
  CodebaseIndex__Operator -->|deserialization: parse| JSON
  CodebaseIndex__Operator__PipelineGuard[\"deserialization"\]
  CodebaseIndex__Operator__PipelineGuard -->|deserialization: parse| JSON
  CodebaseIndex__Operator__PipelineGuard -->|deserialization: parse| Time
  CodebaseIndex__Operator__PipelineGuard -->|deserialization: parse| JSON
  CodebaseIndex__Operator__PipelineGuard_record_[\"deserialization"\]
  CodebaseIndex__Operator__PipelineGuard_record_ -->|deserialization: parse| JSON
  CodebaseIndex__Operator__PipelineGuard_last_run[\"deserialization"\]
  CodebaseIndex__Operator__PipelineGuard_last_run -->|deserialization: parse| Time
  CodebaseIndex__Operator__PipelineGuard_read_state[\"deserialization"\]
  CodebaseIndex__Operator__PipelineGuard_read_state -->|deserialization: parse| JSON
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex__Operator -->|deserialization: parse| JSON
  CodebaseIndex__Operator__StatusReporter[\"deserialization"\]
  CodebaseIndex__Operator__StatusReporter -->|deserialization: parse| JSON
  CodebaseIndex__Operator__StatusReporter_read_manifest[\"deserialization"\]
  CodebaseIndex__Operator__StatusReporter_read_manifest -->|deserialization: parse| JSON
  CodebaseIndex -->|construction: new| Mutex
  CodebaseIndex__Resilience(["new"])
  CodebaseIndex__Resilience -->|construction: new| Mutex
  CodebaseIndex__Resilience__CircuitBreaker(["new"])
  CodebaseIndex__Resilience__CircuitBreaker -->|construction: new| Mutex
  CodebaseIndex__Resilience__CircuitBreaker_initialize(["new"])
  CodebaseIndex__Resilience__CircuitBreaker_initialize -->|construction: new| Mutex
  CodebaseIndex -->|construction: new| Struct
  ValidationReport["ValidationReport"]
  CodebaseIndex -->|construction: new| ValidationReport
  CodebaseIndex -->|construction: new| ValidationReport
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex -->|construction: new| Set
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex__Resilience -->|construction: new| Struct
  CodebaseIndex__Resilience -->|construction: new| ValidationReport
  CodebaseIndex__Resilience -->|construction: new| ValidationReport
  CodebaseIndex__Resilience -->|deserialization: parse| JSON
  CodebaseIndex__Resilience -->|construction: new| Set
  CodebaseIndex__Resilience -->|deserialization: parse| JSON
  CodebaseIndex__Resilience__IndexValidator(["new"])
  CodebaseIndex__Resilience__IndexValidator -->|construction: new| Struct
  CodebaseIndex__Resilience__IndexValidator -->|construction: new| ValidationReport
  CodebaseIndex__Resilience__IndexValidator -->|construction: new| ValidationReport
  CodebaseIndex__Resilience__IndexValidator -->|deserialization: parse| JSON
  CodebaseIndex__Resilience__IndexValidator -->|construction: new| Set
  CodebaseIndex__Resilience__IndexValidator -->|deserialization: parse| JSON
  CodebaseIndex__Resilience__IndexValidator_validate(["new"])
  CodebaseIndex__Resilience__IndexValidator_validate -->|construction: new| ValidationReport
  CodebaseIndex__Resilience__IndexValidator_validate -->|construction: new| ValidationReport
  CodebaseIndex__Resilience__IndexValidator_validate_type_directory(["parse"])
  CodebaseIndex__Resilience__IndexValidator_validate_type_directory -->|deserialization: parse| JSON
  CodebaseIndex__Resilience__IndexValidator_validate_type_directory -->|construction: new| Set
  CodebaseIndex__Resilience__IndexValidator_validate_content_hash[\"deserialization"\]
  CodebaseIndex__Resilience__IndexValidator_validate_content_hash -->|deserialization: parse| JSON
  AssembledContext["AssembledContext"]
  CodebaseIndex -->|construction: new| AssembledContext
  CodebaseIndex -->|construction: new| Struct
  CodebaseIndex__Retrieval(["new"])
  CodebaseIndex__Retrieval -->|construction: new| AssembledContext
  CodebaseIndex__Retrieval -->|construction: new| Struct
  CodebaseIndex__Retrieval__ContextAssembler(["new"])
  CodebaseIndex__Retrieval__ContextAssembler -->|construction: new| AssembledContext
  CodebaseIndex__Retrieval__ContextAssembler_build_result(["new"])
  CodebaseIndex__Retrieval__ContextAssembler_build_result -->|construction: new| AssembledContext
  CodebaseIndex -->|construction: new| Struct
  CodebaseIndex -->|construction: new| Set
  Classification["Classification"]
  CodebaseIndex -->|construction: new| Classification
  CodebaseIndex__Retrieval -->|construction: new| Struct
  CodebaseIndex__Retrieval -->|construction: new| Set
  CodebaseIndex__Retrieval -->|construction: new| Classification
  CodebaseIndex__Retrieval__QueryClassifier(["new"])
  CodebaseIndex__Retrieval__QueryClassifier -->|construction: new| Struct
  CodebaseIndex__Retrieval__QueryClassifier -->|construction: new| Set
  CodebaseIndex__Retrieval__QueryClassifier -->|construction: new| Classification
  CodebaseIndex__Retrieval__QueryClassifier_classify(["new"])
  CodebaseIndex__Retrieval__QueryClassifier_classify -->|construction: new| Classification
  CodebaseIndex -->|construction: new| Hash
  CodebaseIndex -->|construction: new| Hash
  CodebaseIndex -->|construction: new| Hash
  SearchExecutor__Candidate["SearchExecutor::Candidate"]
  CodebaseIndex -->|construction: new| SearchExecutor__Candidate
  CodebaseIndex__Retrieval -->|construction: new| Hash
  CodebaseIndex__Retrieval -->|construction: new| Hash
  CodebaseIndex__Retrieval -->|construction: new| Hash
  CodebaseIndex__Retrieval -->|construction: new| SearchExecutor__Candidate
  CodebaseIndex__Retrieval__Ranker(["new"])
  CodebaseIndex__Retrieval__Ranker -->|construction: new| Hash
  CodebaseIndex__Retrieval__Ranker -->|construction: new| Hash
  CodebaseIndex__Retrieval__Ranker -->|construction: new| Hash
  CodebaseIndex__Retrieval__Ranker -->|construction: new| SearchExecutor__Candidate
  CodebaseIndex__Retrieval__Ranker_compute_rrf_scores(["new"])
  CodebaseIndex__Retrieval__Ranker_compute_rrf_scores -->|construction: new| Hash
  CodebaseIndex__Retrieval__Ranker_apply_diversity_penalty(["new"])
  CodebaseIndex__Retrieval__Ranker_apply_diversity_penalty -->|construction: new| Hash
  CodebaseIndex__Retrieval__Ranker_apply_diversity_penalty -->|construction: new| Hash
  CodebaseIndex__Retrieval__Ranker_build_candidate(["new"])
  CodebaseIndex__Retrieval__Ranker_build_candidate -->|construction: new| SearchExecutor__Candidate
  CodebaseIndex -->|construction: new| Struct
  CodebaseIndex -->|construction: new| Struct
  ExecutionResult["ExecutionResult"]
  CodebaseIndex -->|construction: new| ExecutionResult
  Candidate["Candidate"]
  CodebaseIndex -->|construction: new| Candidate
  CodebaseIndex -->|construction: new| Candidate
  CodebaseIndex__Retrieval -->|construction: new| Struct
  CodebaseIndex__Retrieval -->|construction: new| Struct
  CodebaseIndex__Retrieval -->|construction: new| ExecutionResult
  CodebaseIndex__Retrieval -->|construction: new| Candidate
  CodebaseIndex__Retrieval -->|construction: new| Candidate
  CodebaseIndex__Retrieval__SearchExecutor(["new"])
  CodebaseIndex__Retrieval__SearchExecutor -->|construction: new| Struct
  CodebaseIndex__Retrieval__SearchExecutor -->|construction: new| Struct
  CodebaseIndex__Retrieval__SearchExecutor -->|construction: new| ExecutionResult
  CodebaseIndex__Retrieval__SearchExecutor -->|construction: new| Candidate
  CodebaseIndex__Retrieval__SearchExecutor -->|construction: new| Candidate
  CodebaseIndex__Retrieval__SearchExecutor_execute(["new"])
  CodebaseIndex__Retrieval__SearchExecutor_execute -->|construction: new| ExecutionResult
  CodebaseIndex__Retrieval__SearchExecutor_execute_vector(["new"])
  CodebaseIndex__Retrieval__SearchExecutor_execute_vector -->|construction: new| Candidate
  CodebaseIndex__Retrieval__SearchExecutor_rank_keyword_results(["new"])
  CodebaseIndex__Retrieval__SearchExecutor_rank_keyword_results -->|construction: new| Candidate
  CodebaseIndex -->|construction: new| Struct
  CodebaseIndex -->|construction: new| Struct
  Retrieval__QueryClassifier["Retrieval::QueryClassifier"]
  CodebaseIndex -->|construction: new| Retrieval__QueryClassifier
  Retrieval__SearchExecutor["Retrieval::SearchExecutor"]
  CodebaseIndex -->|construction: new| Retrieval__SearchExecutor
  Retrieval__Ranker["Retrieval::Ranker"]
  CodebaseIndex -->|construction: new| Retrieval__Ranker
  Retrieval__ContextAssembler["Retrieval::ContextAssembler"]
  CodebaseIndex -->|construction: new| Retrieval__ContextAssembler
  RetrievalTrace["RetrievalTrace"]
  CodebaseIndex -->|construction: new| RetrievalTrace
  RetrievalResult["RetrievalResult"]
  CodebaseIndex -->|construction: new| RetrievalResult
  CodebaseIndex__Retriever(["new"])
  CodebaseIndex__Retriever -->|construction: new| Struct
  CodebaseIndex__Retriever -->|construction: new| Struct
  CodebaseIndex__Retriever -->|construction: new| Retrieval__QueryClassifier
  CodebaseIndex__Retriever -->|construction: new| Retrieval__SearchExecutor
  CodebaseIndex__Retriever -->|construction: new| Retrieval__Ranker
  CodebaseIndex__Retriever -->|construction: new| Retrieval__ContextAssembler
  CodebaseIndex__Retriever -->|construction: new| RetrievalTrace
  CodebaseIndex__Retriever -->|construction: new| RetrievalResult
  CodebaseIndex__Retriever_initialize(["new"])
  CodebaseIndex__Retriever_initialize -->|construction: new| Retrieval__QueryClassifier
  CodebaseIndex__Retriever_initialize -->|construction: new| Retrieval__SearchExecutor
  CodebaseIndex__Retriever_initialize -->|construction: new| Retrieval__Ranker
  CodebaseIndex__Retriever_initialize -->|construction: new| Retrieval__ContextAssembler
  CodebaseIndex__Retriever_retrieve(["new"])
  CodebaseIndex__Retriever_retrieve -->|construction: new| RetrievalTrace
  CodebaseIndex__Retriever_build_result(["new"])
  CodebaseIndex__Retriever_build_result -->|construction: new| RetrievalResult
  CodebaseIndex -->|construction: new| Ast__Parser
  CodebaseIndex -->|deserialization: parse| _parser
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__RubyAnalyzer(["new"])
  CodebaseIndex__RubyAnalyzer -->|construction: new| Ast__Parser
  CodebaseIndex__RubyAnalyzer -->|deserialization: parse| _parser
  CodebaseIndex__RubyAnalyzer -->|construction: new| ExtractedUnit
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer(["new"])
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer -->|construction: new| Ast__Parser
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer -->|deserialization: parse| _parser
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer -->|construction: new| ExtractedUnit
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_initialize(["new"])
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_initialize -->|construction: new| Ast__Parser
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_analyze[\"deserialization"\]
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_analyze -->|deserialization: parse| _parser
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_process_definition(["new"])
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_process_definition -->|construction: new| ExtractedUnit
  CodebaseIndex -->|construction: new| Ast__Parser
  Ast__CallSiteExtractor["Ast::CallSiteExtractor"]
  CodebaseIndex -->|construction: new| Ast__CallSiteExtractor
  CodebaseIndex -->|deserialization: parse| _parser
  CodebaseIndex__RubyAnalyzer -->|construction: new| Ast__Parser
  CodebaseIndex__RubyAnalyzer -->|construction: new| Ast__CallSiteExtractor
  CodebaseIndex__RubyAnalyzer -->|deserialization: parse| _parser
  CodebaseIndex__RubyAnalyzer__DataFlowAnalyzer(["new"])
  CodebaseIndex__RubyAnalyzer__DataFlowAnalyzer -->|construction: new| Ast__Parser
  CodebaseIndex__RubyAnalyzer__DataFlowAnalyzer -->|construction: new| Ast__CallSiteExtractor
  CodebaseIndex__RubyAnalyzer__DataFlowAnalyzer -->|deserialization: parse| _parser
  CodebaseIndex__RubyAnalyzer__DataFlowAnalyzer_initialize(["new"])
  CodebaseIndex__RubyAnalyzer__DataFlowAnalyzer_initialize -->|construction: new| Ast__Parser
  CodebaseIndex__RubyAnalyzer__DataFlowAnalyzer_initialize -->|construction: new| Ast__CallSiteExtractor
  CodebaseIndex__RubyAnalyzer__DataFlowAnalyzer_detect_transformations[\"deserialization"\]
  CodebaseIndex__RubyAnalyzer__DataFlowAnalyzer_detect_transformations -->|deserialization: parse| _parser
  CodebaseIndex -->|construction: new| Ast__Parser
  CodebaseIndex -->|construction: new| Ast__CallSiteExtractor
  CodebaseIndex -->|deserialization: parse| _parser
  VisibilityTracker["VisibilityTracker"]
  CodebaseIndex -->|construction: new| VisibilityTracker
  CodebaseIndex -->|construction: new| ExtractedUnit
  CodebaseIndex__RubyAnalyzer -->|construction: new| Ast__Parser
  CodebaseIndex__RubyAnalyzer -->|construction: new| Ast__CallSiteExtractor
  CodebaseIndex__RubyAnalyzer -->|deserialization: parse| _parser
  CodebaseIndex__RubyAnalyzer -->|construction: new| VisibilityTracker
  CodebaseIndex__RubyAnalyzer -->|construction: new| ExtractedUnit
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer(["new"])
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer -->|construction: new| Ast__Parser
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer -->|construction: new| Ast__CallSiteExtractor
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer -->|deserialization: parse| _parser
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer -->|construction: new| VisibilityTracker
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer -->|construction: new| ExtractedUnit
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer_initialize(["new"])
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer_initialize -->|construction: new| Ast__Parser
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer_initialize -->|construction: new| Ast__CallSiteExtractor
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer_analyze[\"deserialization"\]
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer_analyze -->|deserialization: parse| _parser
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer_process_container_methods(["new"])
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer_process_container_methods -->|construction: new| VisibilityTracker
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer_build_method_unit(["new"])
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer_build_method_unit -->|construction: new| ExtractedUnit
  TracePoint["TracePoint"]
  CodebaseIndex -->|construction: new| TracePoint
  CodebaseIndex -->|construction: new| Hash
  CodebaseIndex__RubyAnalyzer -->|construction: new| TracePoint
  CodebaseIndex__RubyAnalyzer -->|construction: new| Hash
  CodebaseIndex__RubyAnalyzer__TraceEnricher(["new"])
  CodebaseIndex__RubyAnalyzer__TraceEnricher -->|construction: new| TracePoint
  CodebaseIndex__RubyAnalyzer__TraceEnricher -->|construction: new| Hash
  CodebaseIndex__RubyAnalyzer__TraceEnricher_record(["new"])
  CodebaseIndex__RubyAnalyzer__TraceEnricher_record -->|construction: new| TracePoint
  CodebaseIndex -->|construction: new| Ast__Parser
  ClassAnalyzer["ClassAnalyzer"]
  CodebaseIndex -->|construction: new| ClassAnalyzer
  MethodAnalyzer["MethodAnalyzer"]
  CodebaseIndex -->|construction: new| MethodAnalyzer
  DataFlowAnalyzer["DataFlowAnalyzer"]
  CodebaseIndex -->|construction: new| DataFlowAnalyzer
  CodebaseIndex__RubyAnalyzer -->|construction: new| Ast__Parser
  CodebaseIndex__RubyAnalyzer -->|construction: new| ClassAnalyzer
  CodebaseIndex__RubyAnalyzer -->|construction: new| MethodAnalyzer
  CodebaseIndex__RubyAnalyzer -->|construction: new| DataFlowAnalyzer
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex__SessionTracer[\"deserialization"\]
  CodebaseIndex__SessionTracer -->|deserialization: parse| JSON
  CodebaseIndex__SessionTracer__FileStore[\"deserialization"\]
  CodebaseIndex__SessionTracer__FileStore -->|deserialization: parse| JSON
  CodebaseIndex__SessionTracer__FileStore_read[\"deserialization"\]
  CodebaseIndex__SessionTracer__FileStore_read -->|deserialization: parse| JSON
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex__SessionTracer -->|deserialization: parse| JSON
  CodebaseIndex__SessionTracer__RedisStore[\"deserialization"\]
  CodebaseIndex__SessionTracer__RedisStore -->|deserialization: parse| JSON
  CodebaseIndex__SessionTracer__RedisStore_read[\"deserialization"\]
  CodebaseIndex__SessionTracer__RedisStore_read -->|deserialization: parse| JSON
  CodebaseIndex -->|construction: new| Set
  SessionFlowDocument["SessionFlowDocument"]
  CodebaseIndex -->|construction: new| SessionFlowDocument
  CodebaseIndex -->|construction: new| SessionFlowDocument
  CodebaseIndex__SessionTracer -->|construction: new| Set
  CodebaseIndex__SessionTracer -->|construction: new| SessionFlowDocument
  CodebaseIndex__SessionTracer -->|construction: new| SessionFlowDocument
  CodebaseIndex__SessionTracer__SessionFlowAssembler -->|construction: new| Set
  CodebaseIndex__SessionTracer__SessionFlowAssembler -->|construction: new| SessionFlowDocument
  CodebaseIndex__SessionTracer__SessionFlowAssembler -->|construction: new| SessionFlowDocument
  CodebaseIndex__SessionTracer__SessionFlowAssembler_assemble(["new"])
  CodebaseIndex__SessionTracer__SessionFlowAssembler_assemble -->|construction: new| Set
  CodebaseIndex__SessionTracer__SessionFlowAssembler_assemble -->|construction: new| SessionFlowDocument
  CodebaseIndex__SessionTracer__SessionFlowAssembler_empty_document(["new"])
  CodebaseIndex__SessionTracer__SessionFlowAssembler_empty_document -->|construction: new| SessionFlowDocument
  CodebaseIndex__SessionTracer__SessionFlowDocument(["new"])
  CodebaseIndex__SessionTracer__SessionFlowDocument_from_h(["new"])
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex__SessionTracer -->|deserialization: parse| JSON
  CodebaseIndex__SessionTracer -->|deserialization: parse| JSON
  CodebaseIndex__SessionTracer -->|deserialization: parse| JSON
  CodebaseIndex__SessionTracer__SolidCacheStore[\"deserialization"\]
  CodebaseIndex__SessionTracer__SolidCacheStore -->|deserialization: parse| JSON
  CodebaseIndex__SessionTracer__SolidCacheStore -->|deserialization: parse| JSON
  CodebaseIndex__SessionTracer__SolidCacheStore -->|deserialization: parse| JSON
  CodebaseIndex__SessionTracer__SolidCacheStore_record[\"deserialization"\]
  CodebaseIndex__SessionTracer__SolidCacheStore_record -->|deserialization: parse| JSON
  CodebaseIndex__SessionTracer__SolidCacheStore_read[\"deserialization"\]
  CodebaseIndex__SessionTracer__SolidCacheStore_read -->|deserialization: parse| JSON
  CodebaseIndex__SessionTracer__SolidCacheStore_read_index[\"deserialization"\]
  CodebaseIndex__SessionTracer__SolidCacheStore_read_index -->|deserialization: parse| JSON
  CodebaseIndex -->|construction: new| DependencyGraph
  CodebaseIndex__Storage(["new"])
  CodebaseIndex__Storage -->|construction: new| DependencyGraph
  CodebaseIndex__Storage__GraphStore(["new"])
  CodebaseIndex__Storage__GraphStore -->|construction: new| DependencyGraph
  CodebaseIndex__Storage__GraphStore__Memory(["new"])
  CodebaseIndex__Storage__GraphStore__Memory -->|construction: new| DependencyGraph
  CodebaseIndex__Storage__GraphStore__Memory_initialize(["new"])
  CodebaseIndex__Storage__GraphStore__Memory_initialize -->|construction: new| DependencyGraph
  SQLite3__Database["SQLite3::Database"]
  CodebaseIndex -->|construction: new| SQLite3__Database
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex__Storage -->|construction: new| SQLite3__Database
  CodebaseIndex__Storage -->|deserialization: parse| JSON
  CodebaseIndex__Storage -->|deserialization: parse| JSON
  CodebaseIndex__Storage -->|deserialization: parse| JSON
  CodebaseIndex__Storage__MetadataStore(["new"])
  CodebaseIndex__Storage__MetadataStore -->|construction: new| SQLite3__Database
  CodebaseIndex__Storage__MetadataStore -->|deserialization: parse| JSON
  CodebaseIndex__Storage__MetadataStore -->|deserialization: parse| JSON
  CodebaseIndex__Storage__MetadataStore -->|deserialization: parse| JSON
  CodebaseIndex__Storage__MetadataStore__SQLite(["new"])
  CodebaseIndex__Storage__MetadataStore__SQLite -->|construction: new| SQLite3__Database
  CodebaseIndex__Storage__MetadataStore__SQLite -->|deserialization: parse| JSON
  CodebaseIndex__Storage__MetadataStore__SQLite -->|deserialization: parse| JSON
  CodebaseIndex__Storage__MetadataStore__SQLite -->|deserialization: parse| JSON
  CodebaseIndex__Storage__MetadataStore__SQLite_initialize(["new"])
  CodebaseIndex__Storage__MetadataStore__SQLite_initialize -->|construction: new| SQLite3__Database
  CodebaseIndex__Storage__MetadataStore__SQLite_find[\"deserialization"\]
  CodebaseIndex__Storage__MetadataStore__SQLite_find -->|deserialization: parse| JSON
  CodebaseIndex__Storage__MetadataStore__SQLite_find_by_type[\"deserialization"\]
  CodebaseIndex__Storage__MetadataStore__SQLite_find_by_type -->|deserialization: parse| JSON
  CodebaseIndex__Storage__MetadataStore__SQLite_search[\"deserialization"\]
  CodebaseIndex__Storage__MetadataStore__SQLite_search -->|deserialization: parse| JSON
  CodebaseIndex -->|deserialization: parse| JSON
  SearchResult["SearchResult"]
  CodebaseIndex -->|construction: new| SearchResult
  CodebaseIndex__Storage -->|deserialization: parse| JSON
  CodebaseIndex__Storage -->|construction: new| SearchResult
  CodebaseIndex__Storage__VectorStore(["parse"])
  CodebaseIndex__Storage__VectorStore -->|deserialization: parse| JSON
  CodebaseIndex__Storage__VectorStore -->|construction: new| SearchResult
  CodebaseIndex__Storage__VectorStore__Pgvector(["parse"])
  CodebaseIndex__Storage__VectorStore__Pgvector -->|deserialization: parse| JSON
  CodebaseIndex__Storage__VectorStore__Pgvector -->|construction: new| SearchResult
  CodebaseIndex__Storage__VectorStore__Pgvector_row_to_result(["parse"])
  CodebaseIndex__Storage__VectorStore__Pgvector_row_to_result -->|deserialization: parse| JSON
  CodebaseIndex__Storage__VectorStore__Pgvector_row_to_result -->|construction: new| SearchResult
  CodebaseIndex -->|construction: new| SearchResult
  CodebaseIndex -->|deserialization: parse| JSON
  CodebaseIndex -->|construction: new| Net__HTTP
  request_class["request_class"]
  CodebaseIndex -->|construction: new| request_class
  CodebaseIndex__Storage -->|construction: new| SearchResult
  CodebaseIndex__Storage -->|deserialization: parse| JSON
  CodebaseIndex__Storage -->|construction: new| Net__HTTP
  CodebaseIndex__Storage -->|construction: new| request_class
  CodebaseIndex__Storage__VectorStore -->|construction: new| SearchResult
  CodebaseIndex__Storage__VectorStore -->|deserialization: parse| JSON
  CodebaseIndex__Storage__VectorStore -->|construction: new| Net__HTTP
  CodebaseIndex__Storage__VectorStore -->|construction: new| request_class
  CodebaseIndex__Storage__VectorStore__Qdrant(["new"])
  CodebaseIndex__Storage__VectorStore__Qdrant -->|construction: new| SearchResult
  CodebaseIndex__Storage__VectorStore__Qdrant -->|deserialization: parse| JSON
  CodebaseIndex__Storage__VectorStore__Qdrant -->|construction: new| Net__HTTP
  CodebaseIndex__Storage__VectorStore__Qdrant -->|construction: new| request_class
  CodebaseIndex__Storage__VectorStore__Qdrant_search(["new"])
  CodebaseIndex__Storage__VectorStore__Qdrant_search -->|construction: new| SearchResult
  CodebaseIndex__Storage__VectorStore__Qdrant_request[\"deserialization"\]
  CodebaseIndex__Storage__VectorStore__Qdrant_request -->|deserialization: parse| JSON
  CodebaseIndex__Storage__VectorStore__Qdrant_build_http(["new"])
  CodebaseIndex__Storage__VectorStore__Qdrant_build_http -->|construction: new| Net__HTTP
  CodebaseIndex__Storage__VectorStore__Qdrant_build_request(["new"])
  CodebaseIndex__Storage__VectorStore__Qdrant_build_request -->|construction: new| request_class
  CodebaseIndex -->|construction: new| Struct
  CodebaseIndex -->|construction: new| SearchResult
  CodebaseIndex__Storage -->|construction: new| Struct
  CodebaseIndex__Storage -->|construction: new| SearchResult
  CodebaseIndex__Storage__VectorStore -->|construction: new| Struct
  CodebaseIndex__Storage__VectorStore -->|construction: new| SearchResult
  CodebaseIndex__Storage__VectorStore__InMemory(["new"])
  CodebaseIndex__Storage__VectorStore__InMemory -->|construction: new| SearchResult
  CodebaseIndex__Storage__VectorStore__InMemory_search(["new"])
  CodebaseIndex__Storage__VectorStore__InMemory_search -->|construction: new| SearchResult
```
