# Data Flow

```mermaid
flowchart TD
  Woods(["new"])
  Set["Set"]
  Woods -->|construction: new| Set
  Woods__Ast(["new"])
  Woods__Ast -->|construction: new| Set
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
  Woods__Ast__MethodExtractor_extract_method_sources[\"deserialization"\]
  Woods__Ast__MethodExtractor_extract_method_sources -->|deserialization: parse| _parser
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
  condition["condition"]
  Woods -->|serialization: to_h| condition
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
  Woods -->|serialization: to_h| condition
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
  Woods__Ast -->|serialization: to_h| condition
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
  Woods__Ast -->|serialization: to_h| condition
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
  Woods__Ast__Parser -->|serialization: to_h| condition
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
  Woods__Ast__Parser -->|serialization: to_h| condition
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
  Woods__Ast__Parser_convert_prism_if -->|serialization: to_h| condition
  Woods__Ast__Parser_convert_prism_if -->|construction: new| Node
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
  Woods__Ast__Parser_convert_parser_node -->|serialization: to_h| condition
  Woods__Ast__Parser_convert_parser_node -->|construction: new| Node
  Woods__Ast__Parser_convert_parser_node -->|construction: new| Node
  Woods__Ast__Parser_convert_parser_node -->|construction: new| Node
  Woods__Ast__Parser_convert_parser_node -->|construction: new| Node
  Woods__Ast__Parser_convert_parser_node -->|construction: new| Node
  Woods__Ast__Parser_convert_parser_node -->|construction: new| Node
  Tempfile["Tempfile"]
  Woods -->|construction: new| Tempfile
  Woods__AtomicFile(["new"])
  Woods__AtomicFile -->|construction: new| Tempfile
  Woods__AtomicFile_write(["new"])
  Woods__AtomicFile_write -->|construction: new| Tempfile
  Configuration["Configuration"]
  Woods -->|construction: new| Configuration
  Retriever["Retriever"]
  Woods -->|construction: new| Retriever
  Storage__VectorStore__InMemory["Storage::VectorStore::InMemory"]
  Woods -->|construction: new| Storage__VectorStore__InMemory
  Embedding__Provider__OpenAI["Embedding::Provider::OpenAI"]
  Woods -->|construction: new| Embedding__Provider__OpenAI
  Embedding__Provider__Ollama["Embedding::Provider::Ollama"]
  Woods -->|construction: new| Embedding__Provider__Ollama
  Resilience__RetryableProvider["Resilience::RetryableProvider"]
  Woods -->|construction: new| Resilience__RetryableProvider
  Resilience__CircuitBreaker["Resilience::CircuitBreaker"]
  Woods -->|construction: new| Resilience__CircuitBreaker
  Embedding__Provider__Fake["Embedding::Provider::Fake"]
  Woods -->|construction: new| Embedding__Provider__Fake
  Embedding__TextPreparer["Embedding::TextPreparer"]
  Woods -->|construction: new| Embedding__TextPreparer
  Chunking__SemanticChunker["Chunking::SemanticChunker"]
  Woods -->|construction: new| Chunking__SemanticChunker
  Embedding__TokenCounter["Embedding::TokenCounter"]
  Woods -->|construction: new| Embedding__TokenCounter
  Storage__MetadataStore__InMemory["Storage::MetadataStore::InMemory"]
  Woods -->|construction: new| Storage__MetadataStore__InMemory
  Storage__MetadataStore__SQLite["Storage::MetadataStore::SQLite"]
  Woods -->|construction: new| Storage__MetadataStore__SQLite
  Storage__GraphStore__Memory["Storage::GraphStore::Memory"]
  Woods -->|construction: new| Storage__GraphStore__Memory
  Storage__VectorStore__Pgvector["Storage::VectorStore::Pgvector"]
  Woods -->|construction: new| Storage__VectorStore__Pgvector
  Storage__VectorStore__Qdrant["Storage::VectorStore::Qdrant"]
  Woods -->|construction: new| Storage__VectorStore__Qdrant
  Cache__InMemory["Cache::InMemory"]
  Woods -->|construction: new| Cache__InMemory
  Cache__RedisCacheStore["Cache::RedisCacheStore"]
  Woods -->|construction: new| Cache__RedisCacheStore
  Cache__SolidCacheStore["Cache::SolidCacheStore"]
  Woods -->|construction: new| Cache__SolidCacheStore
  Cache__CachedEmbeddingProvider["Cache::CachedEmbeddingProvider"]
  Woods -->|construction: new| Cache__CachedEmbeddingProvider
  Cache__CachedRetriever["Cache::CachedRetriever"]
  Woods -->|construction: new| Cache__CachedRetriever
  Woods__Builder(["new"])
  Woods__Builder -->|construction: new| Configuration
  Woods__Builder -->|construction: new| Retriever
  Woods__Builder -->|construction: new| Storage__VectorStore__InMemory
  Woods__Builder -->|construction: new| Embedding__Provider__OpenAI
  Woods__Builder -->|construction: new| Embedding__Provider__Ollama
  Woods__Builder -->|construction: new| Resilience__RetryableProvider
  Woods__Builder -->|construction: new| Resilience__CircuitBreaker
  Woods__Builder -->|construction: new| Embedding__Provider__Fake
  Woods__Builder -->|construction: new| Embedding__TextPreparer
  Woods__Builder -->|construction: new| Chunking__SemanticChunker
  Woods__Builder -->|construction: new| Embedding__TokenCounter
  Woods__Builder -->|construction: new| Storage__MetadataStore__InMemory
  Woods__Builder -->|construction: new| Storage__MetadataStore__SQLite
  Woods__Builder -->|construction: new| Storage__GraphStore__Memory
  Woods__Builder -->|construction: new| Storage__VectorStore__Pgvector
  Woods__Builder -->|construction: new| Storage__VectorStore__Qdrant
  Woods__Builder -->|construction: new| Cache__InMemory
  Woods__Builder -->|construction: new| Cache__RedisCacheStore
  Woods__Builder -->|construction: new| Cache__SolidCacheStore
  Woods__Builder -->|construction: new| Cache__CachedEmbeddingProvider
  Woods__Builder -->|construction: new| Cache__CachedRetriever
  Woods__Builder_preset_config(["new"])
  Woods__Builder_preset_config -->|construction: new| Configuration
  Woods__Builder_build_retriever(["new"])
  Woods__Builder_build_retriever -->|construction: new| Retriever
  Woods__Builder_build_vector_store(["new"])
  Woods__Builder_build_vector_store -->|construction: new| Storage__VectorStore__InMemory
  Woods__Builder_build_embedding_provider(["new"])
  Woods__Builder_build_embedding_provider -->|construction: new| Embedding__Provider__OpenAI
  Woods__Builder_build_embedding_provider -->|construction: new| Embedding__Provider__Ollama
  Woods__Builder_build_resilient_embedding_provider(["new"])
  Woods__Builder_build_resilient_embedding_provider -->|construction: new| Resilience__RetryableProvider
  Woods__Builder_build_resilient_embedding_provider -->|construction: new| Resilience__CircuitBreaker
  Woods__Builder_build_fake_provider(["new"])
  Woods__Builder_build_fake_provider -->|construction: new| Embedding__Provider__Fake
  Woods__Builder_build_text_preparer(["new"])
  Woods__Builder_build_text_preparer -->|construction: new| Embedding__TextPreparer
  Woods__Builder_build_chunker(["new"])
  Woods__Builder_build_chunker -->|construction: new| Chunking__SemanticChunker
  Woods__Builder_token_counter_for(["new"])
  Woods__Builder_token_counter_for -->|construction: new| Embedding__TokenCounter
  Woods__Builder_build_metadata_store(["new"])
  Woods__Builder_build_metadata_store -->|construction: new| Storage__MetadataStore__InMemory
  Woods__Builder_build_metadata_store -->|construction: new| Storage__MetadataStore__SQLite
  Woods__Builder_build_graph_store(["new"])
  Woods__Builder_build_graph_store -->|construction: new| Storage__GraphStore__Memory
  Woods__Builder_build_pgvector_store(["new"])
  Woods__Builder_build_pgvector_store -->|construction: new| Storage__VectorStore__Pgvector
  Woods__Builder_build_qdrant_store(["new"])
  Woods__Builder_build_qdrant_store -->|construction: new| Storage__VectorStore__Qdrant
  Woods__Builder_build_cache_store(["new"])
  Woods__Builder_build_cache_store -->|construction: new| Cache__InMemory
  Woods__Builder_build_cache_store -->|construction: new| Cache__RedisCacheStore
  Woods__Builder_build_cache_store -->|construction: new| Cache__SolidCacheStore
  Woods__Builder_wrap_with_embedding_cache(["new"])
  Woods__Builder_wrap_with_embedding_cache -->|construction: new| Cache__CachedEmbeddingProvider
  Woods__Builder_wrap_with_retriever_cache(["new"])
  Woods__Builder_wrap_with_retriever_cache -->|construction: new| Cache__CachedRetriever
  Mutex["Mutex"]
  Woods -->|construction: new| Mutex
  ConditionVariable["ConditionVariable"]
  Woods -->|construction: new| ConditionVariable
  Woods -->|construction: new| Mutex
  OwnerAbortedError["OwnerAbortedError"]
  Woods -->|construction: new| OwnerAbortedError
  InflightEntry["InflightEntry"]
  Woods -->|construction: new| InflightEntry
  Woods -->|construction: new| InflightEntry
  Woods -->|construction: new| OwnerAbortedError
  Array["Array"]
  Woods -->|construction: new| Array
  Retriever__RetrievalResult["Retriever::RetrievalResult"]
  Woods -->|construction: new| Retriever__RetrievalResult
  Woods__Cache(["new"])
  Woods__Cache -->|construction: new| Mutex
  Woods__Cache -->|construction: new| ConditionVariable
  Woods__Cache -->|construction: new| Mutex
  Woods__Cache -->|construction: new| OwnerAbortedError
  Woods__Cache -->|construction: new| InflightEntry
  Woods__Cache -->|construction: new| InflightEntry
  Woods__Cache -->|construction: new| OwnerAbortedError
  Woods__Cache -->|construction: new| Array
  Woods__Cache -->|construction: new| Retriever__RetrievalResult
  Woods__Cache__InflightEntry(["new"])
  Woods__Cache__InflightEntry -->|construction: new| Mutex
  Woods__Cache__InflightEntry -->|construction: new| ConditionVariable
  Woods__Cache__CachedEmbeddingProvider(["new"])
  Woods__Cache__CachedEmbeddingProvider -->|construction: new| Mutex
  Woods__Cache__CachedEmbeddingProvider -->|construction: new| OwnerAbortedError
  Woods__Cache__CachedEmbeddingProvider -->|construction: new| InflightEntry
  Woods__Cache__CachedEmbeddingProvider -->|construction: new| InflightEntry
  Woods__Cache__CachedEmbeddingProvider -->|construction: new| OwnerAbortedError
  Woods__Cache__CachedEmbeddingProvider -->|construction: new| Array
  Woods__Cache__CachedRetriever(["new"])
  Woods__Cache__CachedRetriever -->|construction: new| Retriever__RetrievalResult
  Woods__Cache__InflightEntry_initialize(["new"])
  Woods__Cache__InflightEntry_initialize -->|construction: new| Mutex
  Woods__Cache__InflightEntry_initialize -->|construction: new| ConditionVariable
  Woods__Cache__CachedEmbeddingProvider_initialize(["new"])
  Woods__Cache__CachedEmbeddingProvider_initialize -->|construction: new| Mutex
  Woods__Cache__CachedEmbeddingProvider_with_single_flight(["new"])
  Woods__Cache__CachedEmbeddingProvider_with_single_flight -->|construction: new| OwnerAbortedError
  Woods__Cache__CachedEmbeddingProvider_claim_single(["new"])
  Woods__Cache__CachedEmbeddingProvider_claim_single -->|construction: new| InflightEntry
  Woods__Cache__CachedEmbeddingProvider_claim_inflight(["new"])
  Woods__Cache__CachedEmbeddingProvider_claim_inflight -->|construction: new| InflightEntry
  Woods__Cache__CachedEmbeddingProvider_fetch_and_fulfill(["new"])
  Woods__Cache__CachedEmbeddingProvider_fetch_and_fulfill -->|construction: new| OwnerAbortedError
  Woods__Cache__CachedEmbeddingProvider_partition_cached(["new"])
  Woods__Cache__CachedEmbeddingProvider_partition_cached -->|construction: new| Array
  Woods__Cache__CachedRetriever_rehydrate_cached(["new"])
  Woods__Cache__CachedRetriever_rehydrate_cached -->|construction: new| Retriever__RetrievalResult
  Logger["Logger"]
  Woods -->|construction: new| Logger
  Woods -->|construction: new| Mutex
  Woods__Cache -->|construction: new| Logger
  Woods__Cache -->|construction: new| Mutex
  Woods__Cache__CacheStore(["new"])
  Woods__Cache__CacheStore -->|construction: new| Logger
  Woods__Cache__InMemory(["new"])
  Woods__Cache__InMemory -->|construction: new| Mutex
  Woods__Cache__CacheStore_logger(["new"])
  Woods__Cache__CacheStore_logger -->|construction: new| Logger
  Woods__Cache__InMemory_initialize(["new"])
  Woods__Cache__InMemory_initialize -->|construction: new| Mutex
  JSON["JSON"]
  Woods -->|deserialization: parse| JSON
  Woods__Cache -->|deserialization: parse| JSON
  Woods__Cache__RedisCacheStore[\"deserialization"\]
  Woods__Cache__RedisCacheStore -->|deserialization: parse| JSON
  Woods__Cache__RedisCacheStore_read[\"deserialization"\]
  Woods__Cache__RedisCacheStore_read -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods__Cache -->|deserialization: parse| JSON
  Woods__Cache__SolidCacheStore[\"deserialization"\]
  Woods__Cache__SolidCacheStore -->|deserialization: parse| JSON
  Woods__Cache__SolidCacheStore_read[\"deserialization"\]
  Woods__Cache__SolidCacheStore_read -->|deserialization: parse| JSON
  Pathname["Pathname"]
  Woods -->|construction: new| Pathname
  Woods -->|construction: new| Pathname
  Woods__ChangeSet(["new"])
  Woods__ChangeSet -->|construction: new| Pathname
  Woods__ChangeSet -->|construction: new| Pathname
  Woods__ChangeSet_initialize(["new"])
  Woods__ChangeSet_initialize -->|construction: new| Pathname
  Woods__ChangeSet_absolutize(["new"])
  Woods__ChangeSet_absolutize -->|construction: new| Pathname
  Chunk["Chunk"]
  Woods -->|construction: new| Chunk
  ModelChunker["ModelChunker"]
  Woods -->|construction: new| ModelChunker
  ControllerChunker["ControllerChunker"]
  Woods -->|construction: new| ControllerChunker
  MethodChunker["MethodChunker"]
  Woods -->|construction: new| MethodChunker
  Woods -->|construction: new| Chunk
  Woods -->|construction: new| Chunk
  String["String"]
  Woods -->|construction: new| String
  Woods -->|construction: new| String
  Woods__Chunking(["new"])
  Woods__Chunking -->|construction: new| Chunk
  Woods__Chunking -->|construction: new| ModelChunker
  Woods__Chunking -->|construction: new| ControllerChunker
  Woods__Chunking -->|construction: new| MethodChunker
  Woods__Chunking -->|construction: new| Chunk
  Woods__Chunking -->|construction: new| Chunk
  Woods__Chunking -->|construction: new| String
  Woods__Chunking -->|construction: new| String
  Woods__Chunking__ChunkBuilder(["new"])
  Woods__Chunking__ChunkBuilder -->|construction: new| Chunk
  Woods__Chunking__SemanticChunker(["new"])
  Woods__Chunking__SemanticChunker -->|construction: new| ModelChunker
  Woods__Chunking__SemanticChunker -->|construction: new| ControllerChunker
  Woods__Chunking__SemanticChunker -->|construction: new| MethodChunker
  Woods__Chunking__SemanticChunker -->|construction: new| Chunk
  Woods__Chunking__SemanticChunker -->|construction: new| Chunk
  Woods__Chunking__SemanticChunker -->|construction: new| String
  Woods__Chunking__SemanticChunker -->|construction: new| String
  Woods__Chunking__ChunkBuilder_build_chunk(["new"])
  Woods__Chunking__ChunkBuilder_build_chunk -->|construction: new| Chunk
  Woods__Chunking__SemanticChunker_chunks_for(["new"])
  Woods__Chunking__SemanticChunker_chunks_for -->|construction: new| ModelChunker
  Woods__Chunking__SemanticChunker_chunks_for -->|construction: new| ControllerChunker
  Woods__Chunking__SemanticChunker_chunks_for -->|construction: new| MethodChunker
  Woods__Chunking__SemanticChunker_build_whole_chunk(["new"])
  Woods__Chunking__SemanticChunker_build_whole_chunk -->|construction: new| Chunk
  Woods__Chunking__SemanticChunker_split_oversize_chunk(["new"])
  Woods__Chunking__SemanticChunker_split_oversize_chunk -->|construction: new| Chunk
  Woods__Chunking__SemanticChunker_slice_by_lines(["new"])
  Woods__Chunking__SemanticChunker_slice_by_lines -->|construction: new| String
  Woods__Chunking__SemanticChunker_slice_by_lines -->|construction: new| String
  CredentialScanner["CredentialScanner"]
  Woods -->|construction: new| CredentialScanner
  Woods -->|deserialization: parse| JSON
  Woods__Console(["new"])
  Woods__Console -->|construction: new| CredentialScanner
  Woods__Console -->|deserialization: parse| JSON
  Woods__Console__AuditLogger(["new"])
  Woods__Console__AuditLogger -->|construction: new| CredentialScanner
  Woods__Console__AuditLogger -->|deserialization: parse| JSON
  Woods__Console__AuditLogger_initialize(["new"])
  Woods__Console__AuditLogger_initialize -->|construction: new| CredentialScanner
  Woods__Console__AuditLogger_entries[\"deserialization"\]
  Woods__Console__AuditLogger_entries -->|deserialization: parse| JSON
  _secrets["@secrets"]
  Woods -->|serialization: to_a| _secrets
  Woods__Console -->|serialization: to_a| _secrets
  Woods__Console__CredentialIndex(["new"])
  Woods__Console__CredentialIndex -->|serialization: to_a| _secrets
  Woods__Console__CredentialIndex_initialize[/"serialization"/]
  Woods__Console__CredentialIndex_initialize -->|serialization: to_a| _secrets
  MCP__Tool__Response["MCP::Tool::Response"]
  Woods -->|construction: new| MCP__Tool__Response
  Woods -->|construction: new| MCP__Tool__Response
  Woods__Console -->|construction: new| MCP__Tool__Response
  Woods__Console -->|construction: new| MCP__Tool__Response
  Woods__Console__DispatchPipeline(["new"])
  Woods__Console__DispatchPipeline -->|construction: new| MCP__Tool__Response
  Woods__Console__DispatchPipeline -->|construction: new| MCP__Tool__Response
  Woods__Console__DispatchPipeline_success_response(["new"])
  Woods__Console__DispatchPipeline_success_response -->|construction: new| MCP__Tool__Response
  Woods__Console__DispatchPipeline_error_response(["new"])
  Woods__Console__DispatchPipeline_error_response -->|construction: new| MCP__Tool__Response
  Object["Object"]
  Woods -->|construction: new| Object
  SqlValidator["SqlValidator"]
  Woods -->|construction: new| SqlValidator
  ScopePredicateParser["ScopePredicateParser"]
  Woods -->|construction: new| ScopePredicateParser
  parser["parser"]
  Woods -->|deserialization: parse| parser
  Woods__Console -->|construction: new| Object
  Woods__Console -->|construction: new| SqlValidator
  Woods__Console -->|construction: new| ScopePredicateParser
  Woods__Console -->|deserialization: parse| parser
  Woods__Console__EmbeddedExecutor(["new"])
  Woods__Console__EmbeddedExecutor -->|construction: new| Object
  Woods__Console__EmbeddedExecutor -->|construction: new| SqlValidator
  Woods__Console__EmbeddedExecutor -->|construction: new| ScopePredicateParser
  Woods__Console__EmbeddedExecutor -->|deserialization: parse| parser
  Woods__Console__EmbeddedExecutor_eval_in_sandbox(["new"])
  Woods__Console__EmbeddedExecutor_eval_in_sandbox -->|construction: new| Object
  Woods__Console__EmbeddedExecutor_handle_sql(["new"])
  Woods__Console__EmbeddedExecutor_handle_sql -->|construction: new| SqlValidator
  Woods__Console__EmbeddedExecutor_apply_scope(["new"])
  Woods__Console__EmbeddedExecutor_apply_scope -->|construction: new| ScopePredicateParser
  Woods__Console__EmbeddedExecutor_apply_scope -->|deserialization: parse| parser
  Woods -->|deserialization: parse| _parser
  Woods__Console -->|deserialization: parse| _parser
  Woods__Console__EvalGuard(["new"])
  Woods__Console__EvalGuard -->|deserialization: parse| _parser
  Woods__Console__EvalGuard_parse_or_refuse[\"deserialization"\]
  Woods__Console__EvalGuard_parse_or_refuse -->|deserialization: parse| _parser
  Woods -->|construction: new| Mutex
  Rack__Request["Rack::Request"]
  Woods -->|construction: new| Rack__Request
  MCP__Server__Transports__StreamableHTTPTransport["MCP::Server::Transports::StreamableHTTPTransport"]
  Woods -->|construction: new| MCP__Server__Transports__StreamableHTTPTransport
  ModelValidator["ModelValidator"]
  Woods -->|construction: new| ModelValidator
  SafeContext["SafeContext"]
  Woods -->|construction: new| SafeContext
  Woods__Observability__StructuredLogger["Woods::Observability::StructuredLogger"]
  Woods -->|construction: new| Woods__Observability__StructuredLogger
  Woods__Console -->|construction: new| Mutex
  Woods__Console -->|construction: new| Rack__Request
  Woods__Console -->|construction: new| MCP__Server__Transports__StreamableHTTPTransport
  Woods__Console -->|construction: new| ModelValidator
  Woods__Console -->|construction: new| SafeContext
  Woods__Console -->|construction: new| Woods__Observability__StructuredLogger
  Woods__Console__RackMiddleware(["new"])
  Woods__Console__RackMiddleware -->|construction: new| Mutex
  Woods__Console__RackMiddleware -->|construction: new| Rack__Request
  Woods__Console__RackMiddleware -->|construction: new| MCP__Server__Transports__StreamableHTTPTransport
  Woods__Console__RackMiddleware -->|construction: new| ModelValidator
  Woods__Console__RackMiddleware -->|construction: new| SafeContext
  Woods__Console__RackMiddleware -->|construction: new| Woods__Observability__StructuredLogger
  Woods__Console__RackMiddleware_initialize(["new"])
  Woods__Console__RackMiddleware_initialize -->|construction: new| Mutex
  Woods__Console__RackMiddleware_call(["new"])
  Woods__Console__RackMiddleware_call -->|construction: new| Rack__Request
  Woods__Console__RackMiddleware_ensure_transport(["new"])
  Woods__Console__RackMiddleware_ensure_transport -->|construction: new| MCP__Server__Transports__StreamableHTTPTransport
  Woods__Console__RackMiddleware_build_embedded_server(["new"])
  Woods__Console__RackMiddleware_build_embedded_server -->|construction: new| ModelValidator
  Woods__Console__RackMiddleware_build_embedded_server -->|construction: new| SafeContext
  Woods__Console__RackMiddleware_structured_logger(["new"])
  Woods__Console__RackMiddleware_structured_logger -->|construction: new| Woods__Observability__StructuredLogger
  columns_each_with_index["columns.each_with_index"]
  Woods -->|serialization: to_h| columns_each_with_index
  Woods__Console -->|serialization: to_h| columns_each_with_index
  Woods__Console__Redactor[/"serialization"/]
  Woods__Console__Redactor -->|serialization: to_h| columns_each_with_index
  Woods__Console__Redactor_positional_kv_rules[/"serialization"/]
  Woods__Console__Redactor_positional_kv_rules -->|serialization: to_h| columns_each_with_index
  Woods__Console__ResponseContext(["new"])
  Woods__Console__ResponseContext_build(["new"])
  Woods -->|construction: new| Struct
  SingleConnectionPool["SingleConnectionPool"]
  Woods -->|construction: new| SingleConnectionPool
  Woods -->|construction: new| SafeContext
  Woods__Console -->|construction: new| Struct
  Woods__Console -->|construction: new| SingleConnectionPool
  Woods__Console -->|construction: new| SafeContext
  Woods__Console__SafeContext(["new"])
  Woods__Console__SafeContext -->|construction: new| Struct
  Woods__Console__SafeContext -->|construction: new| SingleConnectionPool
  Woods__Console__SafeContext -->|construction: new| SafeContext
  Woods__Console__SafeContext_initialize(["new"])
  Woods__Console__SafeContext_initialize -->|construction: new| SingleConnectionPool
  Woods__Console__SafeContext_with_redaction_policy(["new"])
  Woods__Console__SafeContext_with_redaction_policy -->|construction: new| SafeContext
  EmbeddedExecutor["EmbeddedExecutor"]
  Woods -->|construction: new| EmbeddedExecutor
  DispatchPipeline["DispatchPipeline"]
  Woods -->|construction: new| DispatchPipeline
  TableGate["TableGate"]
  Woods -->|construction: new| TableGate
  Woods -->|construction: new| CredentialScanner
  MCP__Server["MCP::Server"]
  Woods -->|construction: new| MCP__Server
  Woods -->|construction: new| Woods__Observability__StructuredLogger
  JsonConsoleRenderer["JsonConsoleRenderer"]
  Woods -->|construction: new| JsonConsoleRenderer
  ConsoleResponseRenderer["ConsoleResponseRenderer"]
  Woods -->|construction: new| ConsoleResponseRenderer
  Woods__Console -->|construction: new| EmbeddedExecutor
  Woods__Console -->|construction: new| DispatchPipeline
  Woods__Console -->|construction: new| TableGate
  Woods__Console -->|construction: new| CredentialScanner
  Woods__Console -->|construction: new| MCP__Server
  Woods__Console -->|construction: new| Woods__Observability__StructuredLogger
  Woods__Console -->|construction: new| JsonConsoleRenderer
  Woods__Console -->|construction: new| ConsoleResponseRenderer
  Woods__Console__Server(["new"])
  Woods__Console__Server -->|construction: new| EmbeddedExecutor
  Woods__Console__Server -->|construction: new| DispatchPipeline
  Woods__Console__Server -->|construction: new| TableGate
  Woods__Console__Server -->|construction: new| CredentialScanner
  Woods__Console__Server -->|construction: new| MCP__Server
  Woods__Console__Server -->|construction: new| Woods__Observability__StructuredLogger
  Woods__Console__Server -->|construction: new| JsonConsoleRenderer
  Woods__Console__Server -->|construction: new| ConsoleResponseRenderer
  FORBIDDEN_KEYWORDS["FORBIDDEN_KEYWORDS"]
  Woods -->|serialization: to_h| FORBIDDEN_KEYWORDS
  BODY_FORBIDDEN_KEYWORDS["BODY_FORBIDDEN_KEYWORDS"]
  Woods -->|serialization: to_h| BODY_FORBIDDEN_KEYWORDS
  Woods -->|serialization: to_h| FORBIDDEN_KEYWORDS
  DML_BODY_KEYWORDS["DML_BODY_KEYWORDS"]
  Woods -->|serialization: to_h| DML_BODY_KEYWORDS
  DANGEROUS_FUNCTIONS["DANGEROUS_FUNCTIONS"]
  Woods -->|serialization: to_h| DANGEROUS_FUNCTIONS
  Woods__Console -->|serialization: to_h| FORBIDDEN_KEYWORDS
  Woods__Console -->|serialization: to_h| BODY_FORBIDDEN_KEYWORDS
  Woods__Console -->|serialization: to_h| FORBIDDEN_KEYWORDS
  Woods__Console -->|serialization: to_h| DML_BODY_KEYWORDS
  Woods__Console -->|serialization: to_h| DANGEROUS_FUNCTIONS
  Woods__Console__SqlValidator[/"serialization"/]
  Woods__Console__SqlValidator -->|serialization: to_h| FORBIDDEN_KEYWORDS
  Woods__Console__SqlValidator -->|serialization: to_h| BODY_FORBIDDEN_KEYWORDS
  Woods__Console__SqlValidator -->|serialization: to_h| FORBIDDEN_KEYWORDS
  Woods__Console__SqlValidator -->|serialization: to_h| DML_BODY_KEYWORDS
  Woods__Console__SqlValidator -->|serialization: to_h| DANGEROUS_FUNCTIONS
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods__Console -->|construction: new| Set
  Woods__Console -->|construction: new| Set
  Woods__Console__TableGate(["new"])
  Woods__Console__TableGate -->|construction: new| Set
  Woods__Console__TableGate -->|construction: new| Set
  Woods__Console__TableGate_initialize(["new"])
  Woods__Console__TableGate_initialize -->|construction: new| Set
  Woods__Console__TableGate_initialize -->|construction: new| Set
  Regexp["Regexp"]
  Woods -->|construction: new| Regexp
  Woods -->|construction: new| Regexp
  Woods -->|construction: new| Regexp
  Woods -->|construction: new| Regexp
  Woods -->|construction: new| Regexp
  Woods -->|construction: new| Struct
  MCP__Tool__InputSchema["MCP::Tool::InputSchema"]
  Woods -->|construction: new| MCP__Tool__InputSchema
  ToolSpec["ToolSpec"]
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| ToolSpec
  EvalGuard["EvalGuard"]
  Woods -->|construction: new| EvalGuard
  Woods -->|construction: new| ToolSpec
  Woods -->|construction: new| SqlValidator
  Woods -->|construction: new| ToolSpec
  required["required"]
  Woods -->|serialization: to_h| required
  Woods__Console -->|construction: new| Regexp
  Woods__Console -->|construction: new| Regexp
  Woods__Console -->|construction: new| Regexp
  Woods__Console -->|construction: new| Regexp
  Woods__Console -->|construction: new| Regexp
  Woods__Console -->|construction: new| Struct
  Woods__Console -->|construction: new| MCP__Tool__InputSchema
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| EvalGuard
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|construction: new| SqlValidator
  Woods__Console -->|construction: new| ToolSpec
  Woods__Console -->|serialization: to_h| required
  Woods__Console__Server -->|construction: new| Regexp
  Woods__Console__Server -->|construction: new| Regexp
  Woods__Console__Server -->|construction: new| Regexp
  Woods__Console__Server -->|construction: new| Regexp
  Woods__Console__Server -->|construction: new| Regexp
  Woods__Console__Server -->|construction: new| Struct
  Woods__Console__Server -->|construction: new| MCP__Tool__InputSchema
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| EvalGuard
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|construction: new| SqlValidator
  Woods__Console__Server -->|construction: new| ToolSpec
  Woods__Console__Server -->|serialization: to_h| required
  Thread["Thread"]
  Woods -->|construction: new| Thread
  Woods__Coordination(["new"])
  Woods__Coordination -->|construction: new| Thread
  Woods__Coordination__LockHeartbeat(["new"])
  Woods__Coordination__LockHeartbeat -->|construction: new| Thread
  Woods__Coordination__LockHeartbeat_run(["new"])
  Woods__Coordination__LockHeartbeat_start_thread(["new"])
  Woods__Coordination__LockHeartbeat_start_thread -->|construction: new| Thread
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods__Coordination -->|deserialization: parse| JSON
  Woods__Coordination -->|deserialization: parse| JSON
  Woods__Coordination__PipelineLock[\"deserialization"\]
  Woods__Coordination__PipelineLock -->|deserialization: parse| JSON
  Woods__Coordination__PipelineLock -->|deserialization: parse| JSON
  Woods__Coordination__PipelineLock_lock_ownership[\"deserialization"\]
  Woods__Coordination__PipelineLock_lock_ownership -->|deserialization: parse| JSON
  Woods__Coordination__PipelineLock_own_lock_[\"deserialization"\]
  Woods__Coordination__PipelineLock_own_lock_ -->|deserialization: parse| JSON
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
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  __file_map_file_path________["(@file_map[file_path] || [])"]
  Woods -->|serialization: to_a| __file_map_file_path________
  __file_map_f________["(@file_map[f] || [])"]
  Woods -->|serialization: to_a| __file_map_f________
  Woods -->|construction: new| Set
  affected["affected"]
  Woods -->|serialization: to_a| affected
  _reverse_fetch["@reverse.fetch"]
  Woods -->|serialization: to_a| _reverse_fetch
  Woods -->|construction: new| Set
  Array_each_with_object["Array.each_with_object"]
  Woods -->|serialization: to_a| Array_each_with_object
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Array
  _type_index_fetch["@type_index.fetch"]
  Woods -->|serialization: to_a| _type_index_fetch
  Woods -->|construction: new| Set
  node_ids["node_ids"]
  Woods -->|serialization: to_h| node_ids
  Woods -->|serialization: to_h| node_ids
  Hash["Hash"]
  Woods -->|construction: new| Hash
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods__DependencyGraph(["new"])
  Woods__DependencyGraph -->|construction: new| Set
  Woods__DependencyGraph -->|construction: new| Set
  Woods__DependencyGraph -->|construction: new| Set
  Woods__DependencyGraph -->|construction: new| Set
  Woods__DependencyGraph -->|construction: new| Set
  Woods__DependencyGraph -->|serialization: to_a| __file_map_file_path________
  Woods__DependencyGraph -->|serialization: to_a| __file_map_f________
  Woods__DependencyGraph -->|construction: new| Set
  Woods__DependencyGraph -->|serialization: to_a| affected
  Woods__DependencyGraph -->|serialization: to_a| _reverse_fetch
  Woods__DependencyGraph -->|construction: new| Set
  Woods__DependencyGraph -->|serialization: to_a| Array_each_with_object
  Woods__DependencyGraph -->|construction: new| Set
  Woods__DependencyGraph -->|construction: new| Set
  Woods__DependencyGraph -->|construction: new| Array
  Woods__DependencyGraph -->|serialization: to_a| _type_index_fetch
  Woods__DependencyGraph -->|construction: new| Set
  Woods__DependencyGraph -->|serialization: to_h| node_ids
  Woods__DependencyGraph -->|serialization: to_h| node_ids
  Woods__DependencyGraph -->|construction: new| Hash
  Woods__DependencyGraph -->|construction: new| Set
  Woods__DependencyGraph -->|construction: new| Set
  Woods__DependencyGraph -->|construction: new| Set
  Woods__DependencyGraph -->|construction: new| Set
  Woods__DependencyGraph -->|construction: new| Set
  Woods__DependencyGraph -->|construction: new| Set
  Woods__DependencyGraph -->|construction: new| Set
  Woods__DependencyGraph_register(["new"])
  Woods__DependencyGraph_register -->|construction: new| Set
  Woods__DependencyGraph_register -->|construction: new| Set
  Woods__DependencyGraph_register -->|construction: new| Set
  Woods__DependencyGraph_register -->|construction: new| Set
  Woods__DependencyGraph_surviving_edges(["new"])
  Woods__DependencyGraph_surviving_edges -->|construction: new| Set
  Woods__DependencyGraph_identifiers_for_path[/"serialization"/]
  Woods__DependencyGraph_identifiers_for_path -->|serialization: to_a| __file_map_file_path________
  Woods__DependencyGraph_affected_by(["to_a"])
  Woods__DependencyGraph_affected_by -->|serialization: to_a| __file_map_f________
  Woods__DependencyGraph_affected_by -->|construction: new| Set
  Woods__DependencyGraph_affected_by -->|serialization: to_a| affected
  Woods__DependencyGraph_dependents_of(["to_a"])
  Woods__DependencyGraph_dependents_of -->|serialization: to_a| _reverse_fetch
  Woods__DependencyGraph_dependents_of -->|construction: new| Set
  Woods__DependencyGraph_dependents_of -->|serialization: to_a| Array_each_with_object
  Woods__DependencyGraph_dependents_of -->|construction: new| Set
  Woods__DependencyGraph_dependents_of -->|construction: new| Set
  Woods__DependencyGraph_dependents_detail(["new"])
  Woods__DependencyGraph_dependents_detail -->|construction: new| Array
  Woods__DependencyGraph_units_of_type(["to_a"])
  Woods__DependencyGraph_units_of_type -->|serialization: to_a| _type_index_fetch
  Woods__DependencyGraph_units_of_type -->|construction: new| Set
  Woods__DependencyGraph_pagerank[/"serialization"/]
  Woods__DependencyGraph_pagerank -->|serialization: to_h| node_ids
  Woods__DependencyGraph_pagerank_step[/"serialization"/]
  Woods__DependencyGraph_pagerank_step -->|serialization: to_h| node_ids
  Woods__DependencyGraph_resolvable_edge_weights(["new"])
  Woods__DependencyGraph_resolvable_edge_weights -->|construction: new| Hash
  Woods__DependencyGraph_relocate_file_map(["new"])
  Woods__DependencyGraph_relocate_file_map -->|construction: new| Set
  Woods__DependencyGraph_from_h(["new"])
  Woods__DependencyGraph_from_h -->|construction: new| Set
  Woods__DependencyGraph_from_h -->|construction: new| Set
  Woods__DependencyGraph_from_h -->|construction: new| Set
  Woods__DependencyGraph_normalize_file_map(["new"])
  Woods__DependencyGraph_normalize_file_map -->|construction: new| Set
  Woods__DependencyGraph_normalize_file_map -->|construction: new| Set
  Woods__DependencyGraph_normalize_file_map -->|construction: new| Set
  Woods -->|construction: new| Array
  Woods__Embedding(["new"])
  Woods__Embedding -->|construction: new| Array
  Woods__Embedding__Provider(["new"])
  Woods__Embedding__Provider -->|construction: new| Array
  Woods__Embedding__Provider__Fake(["new"])
  Woods__Embedding__Provider__Fake -->|construction: new| Array
  Woods__Embedding__Provider__Fake_text_to_vector(["new"])
  Woods__Embedding__Provider__Fake_text_to_vector -->|construction: new| Array
  Woods__Generation["Woods::Generation"]
  Woods -->|construction: new| Woods__Generation
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| Set
  Woods -->|construction: new| Hash
  ExtractedUnit["ExtractedUnit"]
  Woods -->|construction: new| ExtractedUnit
  IndexArtifact["IndexArtifact"]
  Woods -->|construction: new| IndexArtifact
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| IndexArtifact
  Woods__Embedding -->|construction: new| Woods__Generation
  Woods__Embedding -->|deserialization: parse| JSON
  Woods__Embedding -->|construction: new| Set
  Woods__Embedding -->|construction: new| Hash
  Woods__Embedding -->|construction: new| ExtractedUnit
  Woods__Embedding -->|construction: new| IndexArtifact
  Woods__Embedding -->|deserialization: parse| JSON
  Woods__Embedding -->|construction: new| IndexArtifact
  Woods__Embedding__Indexer(["new"])
  Woods__Embedding__Indexer -->|construction: new| Woods__Generation
  Woods__Embedding__Indexer -->|deserialization: parse| JSON
  Woods__Embedding__Indexer -->|construction: new| Set
  Woods__Embedding__Indexer -->|construction: new| Hash
  Woods__Embedding__Indexer -->|construction: new| ExtractedUnit
  Woods__Embedding__Indexer -->|construction: new| IndexArtifact
  Woods__Embedding__Indexer -->|deserialization: parse| JSON
  Woods__Embedding__Indexer -->|construction: new| IndexArtifact
  Woods__Embedding__Indexer_units_dir(["new"])
  Woods__Embedding__Indexer_units_dir -->|construction: new| Woods__Generation
  Woods__Embedding__Indexer_load_units[\"deserialization"\]
  Woods__Embedding__Indexer_load_units -->|deserialization: parse| JSON
  Woods__Embedding__Indexer_prepare_run(["new"])
  Woods__Embedding__Indexer_prepare_run -->|construction: new| Set
  Woods__Embedding__Indexer_load_durable_store_ids(["new"])
  Woods__Embedding__Indexer_load_durable_store_ids -->|construction: new| Hash
  Woods__Embedding__Indexer_build_unit(["new"])
  Woods__Embedding__Indexer_build_unit -->|construction: new| ExtractedUnit
  Woods__Embedding__Indexer_hydrate_persisted_vectors(["new"])
  Woods__Embedding__Indexer_hydrate_persisted_vectors -->|construction: new| IndexArtifact
  Woods__Embedding__Indexer_load_checkpoint[\"deserialization"\]
  Woods__Embedding__Indexer_load_checkpoint -->|deserialization: parse| JSON
  Woods__Embedding__Indexer_persist_snapshot(["new"])
  Woods__Embedding__Indexer_persist_snapshot -->|construction: new| IndexArtifact
  Net__HTTP__Post["Net::HTTP::Post"]
  Woods -->|construction: new| Net__HTTP__Post
  body["body"]
  Woods -->|serialization: to_json| body
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  RequestError["RequestError"]
  Woods -->|construction: new| RequestError
  Net__HTTP["Net::HTTP"]
  Woods -->|construction: new| Net__HTTP
  Woods__Embedding -->|construction: new| Net__HTTP__Post
  Woods__Embedding -->|serialization: to_json| body
  Woods__Embedding -->|deserialization: parse| JSON
  Woods__Embedding -->|deserialization: parse| JSON
  Woods__Embedding -->|construction: new| RequestError
  Woods__Embedding -->|construction: new| Net__HTTP
  Woods__Embedding__Provider -->|construction: new| Net__HTTP__Post
  Woods__Embedding__Provider -->|serialization: to_json| body
  Woods__Embedding__Provider -->|deserialization: parse| JSON
  Woods__Embedding__Provider -->|deserialization: parse| JSON
  Woods__Embedding__Provider -->|construction: new| RequestError
  Woods__Embedding__Provider -->|construction: new| Net__HTTP
  Woods__Embedding__Provider__OpenAI(["new"])
  Woods__Embedding__Provider__OpenAI -->|construction: new| Net__HTTP__Post
  Woods__Embedding__Provider__OpenAI -->|serialization: to_json| body
  Woods__Embedding__Provider__OpenAI -->|deserialization: parse| JSON
  Woods__Embedding__Provider__OpenAI -->|deserialization: parse| JSON
  Woods__Embedding__Provider__OpenAI -->|construction: new| RequestError
  Woods__Embedding__Provider__OpenAI -->|construction: new| Net__HTTP
  Woods__Embedding__Provider__OpenAI_post_request(["new"])
  Woods__Embedding__Provider__OpenAI_post_request -->|construction: new| Net__HTTP__Post
  Woods__Embedding__Provider__OpenAI_post_request -->|serialization: to_json| body
  Woods__Embedding__Provider__OpenAI_post_request -->|deserialization: parse| JSON
  Woods__Embedding__Provider__OpenAI_post_request -->|deserialization: parse| JSON
  Woods__Embedding__Provider__OpenAI_request_error(["new"])
  Woods__Embedding__Provider__OpenAI_request_error -->|construction: new| RequestError
  Woods__Embedding__Provider__OpenAI_http_client(["new"])
  Woods__Embedding__Provider__OpenAI_http_client -->|construction: new| Net__HTTP
  InvalidEmbeddingResponse["InvalidEmbeddingResponse"]
  Woods -->|construction: new| InvalidEmbeddingResponse
  _0___expected_count_["(0...expected_count)"]
  Woods -->|serialization: to_a| _0___expected_count_
  Woods -->|construction: new| Net__HTTP__Post
  Woods -->|serialization: to_json| body
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| RequestError
  Woods -->|construction: new| Net__HTTP
  Woods__Embedding -->|construction: new| InvalidEmbeddingResponse
  Woods__Embedding -->|serialization: to_a| _0___expected_count_
  Woods__Embedding -->|construction: new| Net__HTTP__Post
  Woods__Embedding -->|serialization: to_json| body
  Woods__Embedding -->|deserialization: parse| JSON
  Woods__Embedding -->|deserialization: parse| JSON
  Woods__Embedding -->|construction: new| RequestError
  Woods__Embedding -->|construction: new| Net__HTTP
  Woods__Embedding__Provider -->|construction: new| InvalidEmbeddingResponse
  Woods__Embedding__Provider -->|serialization: to_a| _0___expected_count_
  Woods__Embedding__Provider -->|construction: new| Net__HTTP__Post
  Woods__Embedding__Provider -->|serialization: to_json| body
  Woods__Embedding__Provider -->|deserialization: parse| JSON
  Woods__Embedding__Provider -->|deserialization: parse| JSON
  Woods__Embedding__Provider -->|construction: new| RequestError
  Woods__Embedding__Provider -->|construction: new| Net__HTTP
  Woods__Embedding__Provider__VectorValidation(["new"])
  Woods__Embedding__Provider__VectorValidation -->|construction: new| InvalidEmbeddingResponse
  Woods__Embedding__Provider__VectorValidation -->|serialization: to_a| _0___expected_count_
  Woods__Embedding__Provider__Ollama(["new"])
  Woods__Embedding__Provider__Ollama -->|construction: new| Net__HTTP__Post
  Woods__Embedding__Provider__Ollama -->|serialization: to_json| body
  Woods__Embedding__Provider__Ollama -->|deserialization: parse| JSON
  Woods__Embedding__Provider__Ollama -->|deserialization: parse| JSON
  Woods__Embedding__Provider__Ollama -->|construction: new| RequestError
  Woods__Embedding__Provider__Ollama -->|construction: new| Net__HTTP
  Woods__Embedding__Provider__VectorValidation_validate_(["new"])
  Woods__Embedding__Provider__VectorValidation_validate_ -->|construction: new| InvalidEmbeddingResponse
  Woods__Embedding__Provider__VectorValidation_validate_indexes_[/"serialization"/]
  Woods__Embedding__Provider__VectorValidation_validate_indexes_ -->|serialization: to_a| _0___expected_count_
  Woods__Embedding__Provider__Ollama_post_request(["new"])
  Woods__Embedding__Provider__Ollama_post_request -->|construction: new| Net__HTTP__Post
  Woods__Embedding__Provider__Ollama_post_request -->|serialization: to_json| body
  Woods__Embedding__Provider__Ollama_post_request -->|deserialization: parse| JSON
  Woods__Embedding__Provider__Ollama_post_request -->|deserialization: parse| JSON
  Woods__Embedding__Provider__Ollama_request_error(["new"])
  Woods__Embedding__Provider__Ollama_request_error -->|construction: new| RequestError
  Woods__Embedding__Provider__Ollama_http_client(["new"])
  Woods__Embedding__Provider__Ollama_http_client -->|construction: new| Net__HTTP
  Woods -->|construction: new| Mutex
  Woods -->|construction: new| Set
  Woods -->|construction: new| Mutex
  Woods__Embedding -->|construction: new| Mutex
  Woods__Embedding -->|construction: new| Set
  Woods__Embedding -->|construction: new| Mutex
  Woods__Embedding__TokenCounter(["new"])
  Woods__Embedding__TokenCounter -->|construction: new| Mutex
  Woods__Embedding__TokenCounter -->|construction: new| Set
  Woods__Embedding__TokenCounter -->|construction: new| Mutex
  Woods__Embedding__TokenCounter_initialize(["new"])
  Woods__Embedding__TokenCounter_initialize -->|construction: new| Mutex
  Woods -->|construction: new| Struct
  Woods -->|deserialization: parse| JSON
  Data["Data"]
  Woods -->|construction: new| Data
  Woods__Evaluation(["new"])
  Woods__Evaluation -->|construction: new| Struct
  Woods__Evaluation -->|deserialization: parse| JSON
  Woods__Evaluation -->|construction: new| Data
  Woods__Evaluation__Baseline(["new"])
  Woods__Evaluation__Baseline -->|construction: new| Struct
  Woods__Evaluation__Baseline -->|deserialization: parse| JSON
  Woods__Evaluation__Baseline -->|construction: new| Data
  Random["Random"]
  Woods -->|construction: new| Random
  Woods -->|construction: new| Random
  Woods -->|construction: new| Mutex
  Woods__Evaluation -->|construction: new| Random
  Woods__Evaluation -->|construction: new| Random
  Woods__Evaluation -->|construction: new| Mutex
  Woods__Evaluation__BaselineRunner(["new"])
  Woods__Evaluation__BaselineRunner -->|construction: new| Random
  Woods__Evaluation__BaselineRunner -->|construction: new| Random
  Woods__Evaluation__BaselineRunner -->|construction: new| Mutex
  Woods__Evaluation__BaselineRunner_initialize(["new"])
  Woods__Evaluation__BaselineRunner_initialize -->|construction: new| Random
  Woods__Evaluation__BaselineRunner_initialize -->|construction: new| Random
  Woods__Evaluation__BaselineRunner_initialize -->|construction: new| Mutex
  Woods -->|construction: new| Struct
  Woods -->|construction: new| Struct
  Woods -->|construction: new| Struct
  EvaluationReport["EvaluationReport"]
  Woods -->|construction: new| EvaluationReport
  _thresholds["@thresholds"]
  Woods -->|serialization: to_h| _thresholds
  ThresholdReport["ThresholdReport"]
  Woods -->|construction: new| ThresholdReport
  QueryResult["QueryResult"]
  Woods -->|construction: new| QueryResult
  METRIC_KEYS["METRIC_KEYS"]
  Woods -->|serialization: to_h| METRIC_KEYS
  Woods__Evaluation -->|construction: new| Struct
  Woods__Evaluation -->|construction: new| Struct
  Woods__Evaluation -->|construction: new| Struct
  Woods__Evaluation -->|construction: new| EvaluationReport
  Woods__Evaluation -->|serialization: to_h| _thresholds
  Woods__Evaluation -->|construction: new| ThresholdReport
  Woods__Evaluation -->|construction: new| QueryResult
  Woods__Evaluation -->|serialization: to_h| METRIC_KEYS
  Woods__Evaluation__Evaluator(["new"])
  Woods__Evaluation__Evaluator -->|construction: new| Struct
  Woods__Evaluation__Evaluator -->|construction: new| Struct
  Woods__Evaluation__Evaluator -->|construction: new| Struct
  Woods__Evaluation__Evaluator -->|construction: new| EvaluationReport
  Woods__Evaluation__Evaluator -->|serialization: to_h| _thresholds
  Woods__Evaluation__Evaluator -->|construction: new| ThresholdReport
  Woods__Evaluation__Evaluator -->|construction: new| QueryResult
  Woods__Evaluation__Evaluator -->|serialization: to_h| METRIC_KEYS
  Woods__Evaluation__Evaluator_evaluate(["new"])
  Woods__Evaluation__Evaluator_evaluate -->|construction: new| EvaluationReport
  Woods__Evaluation__Evaluator_evaluate_thresholds(["to_h"])
  Woods__Evaluation__Evaluator_evaluate_thresholds -->|serialization: to_h| _thresholds
  Woods__Evaluation__Evaluator_evaluate_thresholds -->|construction: new| ThresholdReport
  Woods__Evaluation__Evaluator_evaluate_query(["new"])
  Woods__Evaluation__Evaluator_evaluate_query -->|construction: new| QueryResult
  Woods__Evaluation__Evaluator_empty_aggregates[/"serialization"/]
  Woods__Evaluation__Evaluator_empty_aggregates -->|serialization: to_h| METRIC_KEYS
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
  Woods__ExtractedUnit_serialized_metadata[/"serialization"/]
  Woods__ExtractedUnit_serialized_metadata -->|serialization: to_json| metadata
  Woods -->|construction: new| Pathname
  PayloadStore["PayloadStore"]
  Woods -->|construction: new| PayloadStore
  DependencyGraph["DependencyGraph"]
  Woods -->|construction: new| DependencyGraph
  Woods -->|construction: new| DependencyGraph
  GraphAnalyzer["GraphAnalyzer"]
  Woods -->|construction: new| GraphAnalyzer
  ChangeSet["ChangeSet"]
  Woods -->|construction: new| ChangeSet
  Woods -->|construction: new| Set
  touched["touched"]
  Woods -->|serialization: to_a| touched
  Woods -->|serialization: to_a| touched
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| Set
  Generation["Generation"]
  Woods -->|construction: new| Generation
  Woods__ExtractionError["Woods::ExtractionError"]
  Woods -->|construction: new| Woods__ExtractionError
  Woods -->|construction: new| Generation
  Woods -->|construction: new| GraphAnalyzer
  extractor_class["extractor_class"]
  Woods -->|construction: new| extractor_class
  Woods -->|construction: new| Mutex
  Woods -->|construction: new| Thread
  Woods -->|construction: new| extractor_class
  Woods -->|construction: new| Hash
  FlowPrecomputer["FlowPrecomputer"]
  Woods -->|construction: new| FlowPrecomputer
  unit["unit"]
  Woods -->|serialization: to_h| unit
  Woods -->|construction: new| FlowPrecomputer
  removed["removed"]
  Woods -->|serialization: to_a| removed
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| ExtractedUnit
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods -->|serialization: to_h| unit
  Woods -->|construction: new| Hash
  Woods -->|serialization: to_h| unit
  _dependency_graph["@dependency_graph"]
  Woods -->|serialization: to_h| _dependency_graph
  GitProvenance_new["GitProvenance.new"]
  Woods -->|serialization: to_h| GitProvenance_new
  GitProvenance["GitProvenance"]
  Woods -->|construction: new| GitProvenance
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  SQLite3__Database["SQLite3::Database"]
  Woods -->|construction: new| SQLite3__Database
  Db__Migrator["Db::Migrator"]
  Woods -->|construction: new| Db__Migrator
  Temporal__SnapshotStore["Temporal::SnapshotStore"]
  Woods -->|construction: new| Temporal__SnapshotStore
  Temporal__JsonSnapshotStore["Temporal::JsonSnapshotStore"]
  Woods -->|construction: new| Temporal__JsonSnapshotStore
  Woods -->|serialization: to_h| _dependency_graph
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  EXTRACTORS___["EXTRACTORS.[]"]
  Woods -->|construction: new| EXTRACTORS___
  Woods -->|construction: new| Set
  PathDispatcher["PathDispatcher"]
  Woods -->|construction: new| PathDispatcher
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| PathDispatcher
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  fresh["fresh"]
  Woods -->|serialization: to_a| fresh
  Woods -->|construction: new| PathDispatcher
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods__Extractor(["new"])
  Woods__Extractor -->|construction: new| Pathname
  Woods__Extractor -->|construction: new| PayloadStore
  Woods__Extractor -->|construction: new| DependencyGraph
  Woods__Extractor -->|construction: new| DependencyGraph
  Woods__Extractor -->|construction: new| GraphAnalyzer
  Woods__Extractor -->|construction: new| ChangeSet
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|serialization: to_a| touched
  Woods__Extractor -->|serialization: to_a| touched
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|deserialization: parse| JSON
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| Generation
  Woods__Extractor -->|construction: new| Woods__ExtractionError
  Woods__Extractor -->|construction: new| Generation
  Woods__Extractor -->|construction: new| GraphAnalyzer
  Woods__Extractor -->|construction: new| extractor_class
  Woods__Extractor -->|construction: new| Mutex
  Woods__Extractor -->|construction: new| Thread
  Woods__Extractor -->|construction: new| extractor_class
  Woods__Extractor -->|construction: new| Hash
  Woods__Extractor -->|construction: new| FlowPrecomputer
  Woods__Extractor -->|serialization: to_h| unit
  Woods__Extractor -->|construction: new| FlowPrecomputer
  Woods__Extractor -->|serialization: to_a| removed
  Woods__Extractor -->|deserialization: parse| JSON
  Woods__Extractor -->|deserialization: parse| JSON
  Woods__Extractor -->|construction: new| ExtractedUnit
  Woods__Extractor -->|deserialization: parse| JSON
  Woods__Extractor -->|deserialization: parse| JSON
  Woods__Extractor -->|serialization: to_h| unit
  Woods__Extractor -->|construction: new| Hash
  Woods__Extractor -->|serialization: to_h| unit
  Woods__Extractor -->|serialization: to_h| _dependency_graph
  Woods__Extractor -->|serialization: to_h| GitProvenance_new
  Woods__Extractor -->|construction: new| GitProvenance
  Woods__Extractor -->|deserialization: parse| JSON
  Woods__Extractor -->|deserialization: parse| JSON
  Woods__Extractor -->|construction: new| SQLite3__Database
  Woods__Extractor -->|construction: new| Db__Migrator
  Woods__Extractor -->|construction: new| Temporal__SnapshotStore
  Woods__Extractor -->|construction: new| Temporal__JsonSnapshotStore
  Woods__Extractor -->|serialization: to_h| _dependency_graph
  Woods__Extractor -->|deserialization: parse| JSON
  Woods__Extractor -->|deserialization: parse| JSON
  Woods__Extractor -->|construction: new| EXTRACTORS___
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| PathDispatcher
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| PathDispatcher
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|serialization: to_a| fresh
  Woods__Extractor -->|construction: new| PathDispatcher
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|construction: new| Set
  Woods__Extractor -->|deserialization: parse| JSON
  Woods__Extractor -->|deserialization: parse| JSON
  Woods__Extractor_initialize(["new"])
  Woods__Extractor_initialize -->|construction: new| Pathname
  Woods__Extractor_initialize -->|construction: new| PayloadStore
  Woods__Extractor_initialize -->|construction: new| DependencyGraph
  Woods__Extractor_extract_all(["new"])
  Woods__Extractor_extract_all -->|construction: new| DependencyGraph
  Woods__Extractor_extract_all -->|construction: new| GraphAnalyzer
  Woods__Extractor_extract_changed(["new"])
  Woods__Extractor_extract_changed -->|construction: new| ChangeSet
  Woods__Extractor_extract_changed -->|construction: new| Set
  Woods__Extractor_extract_changed -->|serialization: to_a| touched
  Woods__Extractor_extract_changed -->|serialization: to_a| touched
  Woods__Extractor_refresh(["new"])
  Woods__Extractor_refresh -->|construction: new| Set
  Woods__Extractor_refresh -->|construction: new| Set
  Woods__Extractor_prepare_incremental_run(["parse"])
  Woods__Extractor_prepare_incremental_run -->|deserialization: parse| JSON
  Woods__Extractor_prepare_incremental_run -->|construction: new| Set
  Woods__Extractor_publish_generation(["new"])
  Woods__Extractor_publish_generation -->|construction: new| Generation
  Woods__Extractor_publish_generation -->|construction: new| Woods__ExtractionError
  Woods__Extractor_begin_payload_(["new"])
  Woods__Extractor_begin_payload_ -->|construction: new| Generation
  Woods__Extractor_write_incremental_graph_analysis(["new"])
  Woods__Extractor_write_incremental_graph_analysis -->|construction: new| GraphAnalyzer
  Woods__Extractor_extract_all_sequential(["new"])
  Woods__Extractor_extract_all_sequential -->|construction: new| extractor_class
  Woods__Extractor_extract_all_concurrent(["new"])
  Woods__Extractor_extract_all_concurrent -->|construction: new| Mutex
  Woods__Extractor_extract_all_concurrent -->|construction: new| Thread
  Woods__Extractor_extract_all_concurrent -->|construction: new| extractor_class
  Woods__Extractor_resolve_dependents(["new"])
  Woods__Extractor_resolve_dependents -->|construction: new| Hash
  Woods__Extractor_precompute_flows(["new"])
  Woods__Extractor_precompute_flows -->|construction: new| FlowPrecomputer
  Woods__Extractor_rewrite_flow_annotated_units[/"serialization"/]
  Woods__Extractor_rewrite_flow_annotated_units -->|serialization: to_h| unit
  Woods__Extractor_refresh_incremental_flows(["new"])
  Woods__Extractor_refresh_incremental_flows -->|construction: new| FlowPrecomputer
  Woods__Extractor_refresh_incremental_flows -->|serialization: to_a| removed
  Woods__Extractor_previous_flow_index_controllers[\"deserialization"\]
  Woods__Extractor_previous_flow_index_controllers -->|deserialization: parse| JSON
  Woods__Extractor_unit_from_payload(["parse"])
  Woods__Extractor_unit_from_payload -->|deserialization: parse| JSON
  Woods__Extractor_unit_from_payload -->|construction: new| ExtractedUnit
  Woods__Extractor_patch_flow_annotations[\"deserialization"\]
  Woods__Extractor_patch_flow_annotations -->|deserialization: parse| JSON
  Woods__Extractor_parse_flow_index_for_sweep[\"deserialization"\]
  Woods__Extractor_parse_flow_index_for_sweep -->|deserialization: parse| JSON
  Woods__Extractor_write_unit_file[/"serialization"/]
  Woods__Extractor_write_unit_file -->|serialization: to_h| unit
  Woods__Extractor_parse_git_log_output(["new"])
  Woods__Extractor_parse_git_log_output -->|construction: new| Hash
  Woods__Extractor_write_results[/"serialization"/]
  Woods__Extractor_write_results -->|serialization: to_h| unit
  Woods__Extractor_write_dependency_graph[/"serialization"/]
  Woods__Extractor_write_dependency_graph -->|serialization: to_h| _dependency_graph
  Woods__Extractor_write_manifest(["to_h"])
  Woods__Extractor_write_manifest -->|serialization: to_h| GitProvenance_new
  Woods__Extractor_write_manifest -->|construction: new| GitProvenance
  Woods__Extractor_persisted_counts[\"deserialization"\]
  Woods__Extractor_persisted_counts -->|deserialization: parse| JSON
  Woods__Extractor_capture_snapshot[\"deserialization"\]
  Woods__Extractor_capture_snapshot -->|deserialization: parse| JSON
  Woods__Extractor_build_snapshot_store(["new"])
  Woods__Extractor_build_snapshot_store -->|construction: new| SQLite3__Database
  Woods__Extractor_build_snapshot_store -->|construction: new| Db__Migrator
  Woods__Extractor_build_snapshot_store -->|construction: new| Temporal__SnapshotStore
  Woods__Extractor_build_snapshot_store -->|construction: new| Temporal__JsonSnapshotStore
  Woods__Extractor_write_structural_summary[/"serialization"/]
  Woods__Extractor_write_structural_summary -->|serialization: to_h| _dependency_graph
  Woods__Extractor_persisted_summary_stats[\"deserialization"\]
  Woods__Extractor_persisted_summary_stats -->|deserialization: parse| JSON
  Woods__Extractor_regenerate_type_index[\"deserialization"\]
  Woods__Extractor_regenerate_type_index -->|deserialization: parse| JSON
  Woods__Extractor_extractor_for(["new"])
  Woods__Extractor_extractor_for -->|construction: new| EXTRACTORS___
  Woods__Extractor_active_record_names(["new"])
  Woods__Extractor_active_record_names -->|construction: new| Set
  Woods__Extractor_reconcile_changed_paths(["new"])
  Woods__Extractor_reconcile_changed_paths -->|construction: new| PathDispatcher
  Woods__Extractor_reconcile_changed_paths -->|construction: new| Set
  Woods__Extractor_reconcile_changed_paths -->|construction: new| Set
  Woods__Extractor_prune_path_leftovers(["new"])
  Woods__Extractor_prune_path_leftovers -->|construction: new| Set
  Woods__Extractor_reconcile_class_based_types(["new"])
  Woods__Extractor_reconcile_class_based_types -->|construction: new| Set
  Woods__Extractor_reconcile_class_based_types -->|construction: new| Set
  Woods__Extractor_readdable_pruned_classes(["new"])
  Woods__Extractor_readdable_pruned_classes -->|construction: new| Set
  Woods__Extractor_readdable_pruned_classes -->|construction: new| Set
  Woods__Extractor_add_discovered_classes(["new"])
  Woods__Extractor_add_discovered_classes -->|construction: new| Set
  Woods__Extractor_remove_stale_classes(["new"])
  Woods__Extractor_remove_stale_classes -->|construction: new| Set
  Woods__Extractor_remove_stale_classes -->|construction: new| Set
  Woods__Extractor_rerun_whole_app_extractors(["new"])
  Woods__Extractor_rerun_whole_app_extractors -->|construction: new| PathDispatcher
  Woods__Extractor_rerun_whole_app_extractors -->|construction: new| Set
  Woods__Extractor_rerun_whole_app_extractors -->|construction: new| Set
  Woods__Extractor_replace_type_wholesale(["new"])
  Woods__Extractor_replace_type_wholesale -->|construction: new| Set
  Woods__Extractor_replace_type_wholesale -->|construction: new| Set
  Woods__Extractor_remove_replaced_units(["new"])
  Woods__Extractor_remove_replaced_units -->|construction: new| Set
  Woods__Extractor_remove_replaced_units -->|construction: new| Set
  Woods__Extractor_remove_replaced_units -->|serialization: to_a| fresh
  Woods__Extractor_sweep_candidates(["new"])
  Woods__Extractor_sweep_candidates -->|construction: new| PathDispatcher
  Woods__Extractor_prune_paths(["new"])
  Woods__Extractor_prune_paths -->|construction: new| Set
  Woods__Extractor_register_and_write(["new"])
  Woods__Extractor_register_and_write -->|construction: new| Set
  Woods__Extractor_register_and_write -->|construction: new| Set
  Woods__Extractor_mark_dependents_dirty(["new"])
  Woods__Extractor_mark_dependents_dirty -->|construction: new| Set
  Woods__Extractor_finalize_incremental_unit_json(["new"])
  Woods__Extractor_finalize_incremental_unit_json -->|construction: new| Set
  Woods__Extractor_rewrite_unit_json_of_type[\"deserialization"\]
  Woods__Extractor_rewrite_unit_json_of_type -->|deserialization: parse| JSON
  Woods__Extractor_rewrite_unit_json_of_type -->|deserialization: parse| JSON
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
  Woods__Extractors__AstSourceExtraction_action_sources_for(["new"])
  Woods__Extractors__AstSourceExtraction_action_sources_for -->|construction: new| Ast__MethodExtractor
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
  SINGLE_COLUMN_WRITERS["SINGLE_COLUMN_WRITERS"]
  Woods -->|serialization: to_h| SINGLE_COLUMN_WRITERS
  MULTI_COLUMN_WRITERS["MULTI_COLUMN_WRITERS"]
  Woods -->|serialization: to_h| MULTI_COLUMN_WRITERS
  DB_READ_METHODS["DB_READ_METHODS"]
  Woods -->|serialization: to_h| DB_READ_METHODS
  Ast__Parser["Ast::Parser"]
  Woods -->|construction: new| Ast__Parser
  FlowAnalysis__OperationExtractor["FlowAnalysis::OperationExtractor"]
  Woods -->|construction: new| FlowAnalysis__OperationExtractor
  Woods -->|deserialization: parse| _parser
  Woods -->|construction: new| Set
  columns["columns"]
  Woods -->|serialization: to_a| columns
  Woods__Extractors -->|serialization: to_h| SINGLE_COLUMN_WRITERS
  Woods__Extractors -->|serialization: to_h| MULTI_COLUMN_WRITERS
  Woods__Extractors -->|serialization: to_h| DB_READ_METHODS
  Woods__Extractors -->|construction: new| Ast__Parser
  Woods__Extractors -->|construction: new| FlowAnalysis__OperationExtractor
  Woods__Extractors -->|deserialization: parse| _parser
  Woods__Extractors -->|construction: new| Set
  Woods__Extractors -->|serialization: to_a| columns
  Woods__Extractors__CallbackAnalyzer(["to_h"])
  Woods__Extractors__CallbackAnalyzer -->|serialization: to_h| SINGLE_COLUMN_WRITERS
  Woods__Extractors__CallbackAnalyzer -->|serialization: to_h| MULTI_COLUMN_WRITERS
  Woods__Extractors__CallbackAnalyzer -->|serialization: to_h| DB_READ_METHODS
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
  Woods -->|construction: new| Pathname
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| Pathname
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__ConcernExtractor(["new"])
  Woods__Extractors__ConcernExtractor -->|construction: new| Pathname
  Woods__Extractors__ConcernExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__ConcernExtractor_initialize(["new"])
  Woods__Extractors__ConcernExtractor_initialize -->|construction: new| Pathname
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
  controller_action_methods_select["controller.action_methods.select"]
  Woods -->|serialization: to_a| controller_action_methods_select
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors -->|serialization: to_a| controller_action_methods_select
  Woods__Extractors__ControllerExtractor(["new"])
  Woods__Extractors__ControllerExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__ControllerExtractor -->|serialization: to_a| controller_action_methods_select
  Woods__Extractors__ControllerExtractor_extract_controller(["new"])
  Woods__Extractors__ControllerExtractor_extract_controller -->|construction: new| ExtractedUnit
  Woods__Extractors__ControllerExtractor_extract_metadata[/"serialization"/]
  Woods__Extractors__ControllerExtractor_extract_metadata -->|serialization: to_a| controller_action_methods_select
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
  source_scan_flatten["source.scan.flatten"]
  Woods -->|serialization: to_h| source_scan_flatten
  Woods__Extractors -->|construction: new| Set
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors -->|serialization: to_h| source_scan_flatten
  Woods__Extractors__GraphQLExtractor(["new"])
  Woods__Extractors__GraphQLExtractor -->|construction: new| Set
  Woods__Extractors__GraphQLExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__GraphQLExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__GraphQLExtractor -->|serialization: to_h| source_scan_flatten
  Woods__Extractors__GraphQLExtractor_extract_all(["new"])
  Woods__Extractors__GraphQLExtractor_extract_all -->|construction: new| Set
  Woods__Extractors__GraphQLExtractor_extract_graphql_file(["new"])
  Woods__Extractors__GraphQLExtractor_extract_graphql_file -->|construction: new| ExtractedUnit
  Woods__Extractors__GraphQLExtractor_extract_from_runtime_type(["new"])
  Woods__Extractors__GraphQLExtractor_extract_from_runtime_type -->|construction: new| ExtractedUnit
  Woods__Extractors__GraphQLExtractor_extract_dependencies[/"serialization"/]
  Woods__Extractors__GraphQLExtractor_extract_dependencies -->|serialization: to_h| source_scan_flatten
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
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__LibExtractor(["new"])
  Woods__Extractors__LibExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__LibExtractor_extract_lib_file(["new"])
  Woods__Extractors__LibExtractor_extract_lib_file -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  mailer_action_methods["mailer.action_methods"]
  Woods -->|serialization: to_a| mailer_action_methods
  Woods -->|serialization: to_a| mailer_action_methods
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors -->|serialization: to_a| mailer_action_methods
  Woods__Extractors -->|serialization: to_a| mailer_action_methods
  Woods__Extractors__MailerExtractor(["new"])
  Woods__Extractors__MailerExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__MailerExtractor -->|serialization: to_a| mailer_action_methods
  Woods__Extractors__MailerExtractor -->|serialization: to_a| mailer_action_methods
  Woods__Extractors__MailerExtractor_extract_mailer(["new"])
  Woods__Extractors__MailerExtractor_extract_mailer -->|construction: new| ExtractedUnit
  Woods__Extractors__MailerExtractor_annotate_source[/"serialization"/]
  Woods__Extractors__MailerExtractor_annotate_source -->|serialization: to_a| mailer_action_methods
  Woods__Extractors__MailerExtractor_extract_metadata[/"serialization"/]
  Woods__Extractors__MailerExtractor_extract_metadata -->|serialization: to_a| mailer_action_methods
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
  Woods__Extractors__PoroExtractor(["new"])
  Woods__Extractors__PoroExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__PoroExtractor_extract_poro_file(["new"])
  Woods__Extractors__PoroExtractor_extract_poro_file -->|construction: new| ExtractedUnit
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
  Woods -->|construction: new| Hash
  Woods -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| Hash
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors__RakeTaskExtractor(["new"])
  Woods__Extractors__RakeTaskExtractor -->|construction: new| Hash
  Woods__Extractors__RakeTaskExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__RakeTaskExtractor_all_definitions(["new"])
  Woods__Extractors__RakeTaskExtractor_all_definitions -->|construction: new| Hash
  Woods__Extractors__RakeTaskExtractor_build_unit(["new"])
  Woods__Extractors__RakeTaskExtractor_build_unit -->|construction: new| ExtractedUnit
  Woods -->|construction: new| ExtractedUnit
  Woods -->|construction: new| Hash
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| Hash
  Woods__Extractors__RouteExtractor(["new"])
  Woods__Extractors__RouteExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__RouteExtractor -->|construction: new| Hash
  Woods__Extractors__RouteExtractor_extract_route(["new"])
  Woods__Extractors__RouteExtractor_extract_route -->|construction: new| ExtractedUnit
  Woods__Extractors__RouteExtractor_number_colliding_identifiers(["new"])
  Woods__Extractors__RouteExtractor_number_colliding_identifiers -->|construction: new| Hash
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
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods__Extractors -->|construction: new| Set
  Woods__Extractors -->|construction: new| Set
  Woods__Extractors -->|construction: new| Set
  Woods__Extractors -->|construction: new| Set
  Woods__Extractors__SharedDependencyScanner(["new"])
  Woods__Extractors__SharedDependencyScanner -->|construction: new| Set
  Woods__Extractors__SharedDependencyScanner -->|construction: new| Set
  Woods__Extractors__SharedDependencyScanner -->|construction: new| Set
  Woods__Extractors__SharedDependencyScanner -->|construction: new| Set
  Woods__Extractors__SharedDependencyScanner_scan_model_dependencies(["new"])
  Woods__Extractors__SharedDependencyScanner_scan_model_dependencies -->|construction: new| Set
  Woods__Extractors__SharedDependencyScanner_scan_navigation_dependencies(["new"])
  Woods__Extractors__SharedDependencyScanner_scan_navigation_dependencies -->|construction: new| Set
  Woods__Extractors__SharedDependencyScanner_scan_navigation_dependencies -->|construction: new| Set
  Woods__Extractors__SharedDependencyScanner_scan_form_dependencies(["new"])
  Woods__Extractors__SharedDependencyScanner_scan_form_dependencies -->|construction: new| Set
  actions["actions"]
  Woods -->|serialization: to_a| actions
  Woods__Extractors -->|serialization: to_a| actions
  Woods__Extractors__SharedUtilityMethods[/"serialization"/]
  Woods__Extractors__SharedUtilityMethods -->|serialization: to_a| actions
  Woods__Extractors__SharedUtilityMethods_extract_action_filter_actions[/"serialization"/]
  Woods__Extractors__SharedUtilityMethods_extract_action_filter_actions -->|serialization: to_a| actions
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
  Woods -->|construction: new| Set
  partials["partials"]
  Woods -->|serialization: to_a| partials
  Woods -->|construction: new| Set
  found["found"]
  Woods -->|serialization: to_a| found
  Woods__Extractors -->|construction: new| Set
  Woods__Extractors -->|serialization: to_a| partials
  Woods__Extractors -->|construction: new| Set
  Woods__Extractors -->|serialization: to_a| found
  Woods__Extractors__ViewEngines(["new"])
  Woods__Extractors__ViewEngines -->|construction: new| Set
  Woods__Extractors__ViewEngines -->|serialization: to_a| partials
  Woods__Extractors__ViewEngines -->|construction: new| Set
  Woods__Extractors__ViewEngines -->|serialization: to_a| found
  Woods__Extractors__ViewEngines__Erb(["new"])
  Woods__Extractors__ViewEngines__Erb -->|construction: new| Set
  Woods__Extractors__ViewEngines__Erb -->|serialization: to_a| partials
  Woods__Extractors__ViewEngines__Erb -->|construction: new| Set
  Woods__Extractors__ViewEngines__Erb -->|serialization: to_a| found
  Woods__Extractors__ViewEngines__Erb_scan_partials(["new"])
  Woods__Extractors__ViewEngines__Erb_scan_partials -->|construction: new| Set
  Woods__Extractors__ViewEngines__Erb_scan_partials -->|serialization: to_a| partials
  Woods__Extractors__ViewEngines__Erb_scan_helpers(["new"])
  Woods__Extractors__ViewEngines__Erb_scan_helpers -->|construction: new| Set
  Woods__Extractors__ViewEngines__Erb_scan_helpers -->|serialization: to_a| found
  klass["klass"]
  Woods -->|construction: new| klass
  Woods -->|construction: new| ExtractedUnit
  Woods -->|construction: new| Set
  Woods__Extractors -->|construction: new| klass
  Woods__Extractors -->|construction: new| ExtractedUnit
  Woods__Extractors -->|construction: new| Set
  Woods__Extractors__ViewTemplateExtractor(["new"])
  Woods__Extractors__ViewTemplateExtractor -->|construction: new| klass
  Woods__Extractors__ViewTemplateExtractor -->|construction: new| ExtractedUnit
  Woods__Extractors__ViewTemplateExtractor -->|construction: new| Set
  Woods__Extractors__ViewTemplateExtractor_supported_template_engines(["new"])
  Woods__Extractors__ViewTemplateExtractor_supported_template_engines -->|construction: new| klass
  Woods__Extractors__ViewTemplateExtractor_extract_view_template_file(["new"])
  Woods__Extractors__ViewTemplateExtractor_extract_view_template_file -->|construction: new| ExtractedUnit
  Woods__Extractors__ViewTemplateExtractor_resolve_navigation_candidates(["new"])
  Woods__Extractors__ViewTemplateExtractor_resolve_navigation_candidates -->|construction: new| Set
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
  Woods -->|construction: new| FlowAssembler
  Woods -->|deserialization: parse| JSON
  flow["flow"]
  Woods -->|serialization: to_h| flow
  value_keys_sort_by["value.keys.sort_by"]
  Woods -->|serialization: to_h| value_keys_sort_by
  Woods__FlowPrecomputer(["new"])
  Woods__FlowPrecomputer -->|construction: new| FlowAssembler
  Woods__FlowPrecomputer -->|construction: new| FlowAssembler
  Woods__FlowPrecomputer -->|deserialization: parse| JSON
  Woods__FlowPrecomputer -->|serialization: to_h| flow
  Woods__FlowPrecomputer -->|serialization: to_h| value_keys_sort_by
  Woods__FlowPrecomputer_precompute(["new"])
  Woods__FlowPrecomputer_precompute -->|construction: new| FlowAssembler
  Woods__FlowPrecomputer_recompute_delta(["new"])
  Woods__FlowPrecomputer_recompute_delta -->|construction: new| FlowAssembler
  Woods__FlowPrecomputer_previous_flow_index[\"deserialization"\]
  Woods__FlowPrecomputer_previous_flow_index -->|deserialization: parse| JSON
  Woods__FlowPrecomputer_assemble_and_write[/"serialization"/]
  Woods__FlowPrecomputer_assemble_and_write -->|serialization: to_h| flow
  Woods__FlowPrecomputer_sort_keys_deep[/"serialization"/]
  Woods__FlowPrecomputer_sort_keys_deep -->|serialization: to_h| value_keys_sort_by
  Woods -->|construction: new| Pathname
  Woods -->|construction: new| Pathname
  GemMapSource["GemMapSource"]
  Woods -->|construction: new| GemMapSource
  GemMapPublisher["GemMapPublisher"]
  Woods -->|construction: new| GemMapPublisher
  Coordination__PipelineLock["Coordination::PipelineLock"]
  Woods -->|construction: new| Coordination__PipelineLock
  source_files["source_files"]
  Woods -->|serialization: to_h| source_files
  Digest__SHA256["Digest::SHA256"]
  Woods -->|construction: new| Digest__SHA256
  Woods -->|construction: new| Generation
  Woods -->|construction: new| Generation
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| Pathname
  Woods -->|construction: new| PayloadStore
  Woods -->|construction: new| Generation
  Woods -->|construction: new| PayloadStore
  Woods -->|construction: new| DependencyGraph
  Woods -->|construction: new| ExtractedUnit
  Woods -->|construction: new| Pathname
  Woods -->|serialization: to_h| unit
  _graph["@graph"]
  Woods -->|serialization: to_h| _graph
  Woods -->|construction: new| GraphAnalyzer
  GemMapper__TYPE_DIRECTORIES_keys["GemMapper::TYPE_DIRECTORIES.keys"]
  Woods -->|serialization: to_h| GemMapper__TYPE_DIRECTORIES_keys
  Woods -->|serialization: to_h| _graph
  Woods__GemMapper(["new"])
  Woods__GemMapper -->|construction: new| Pathname
  Woods__GemMapper -->|construction: new| Pathname
  Woods__GemMapper -->|construction: new| GemMapSource
  Woods__GemMapper -->|construction: new| GemMapPublisher
  Woods__GemMapper -->|construction: new| Coordination__PipelineLock
  Woods__GemMapper -->|serialization: to_h| source_files
  Woods__GemMapper -->|construction: new| Digest__SHA256
  Woods__GemMapper -->|construction: new| Generation
  Woods__GemMapper -->|construction: new| Generation
  Woods__GemMapper -->|deserialization: parse| JSON
  Woods__GemMapper -->|construction: new| Pathname
  Woods__GemMapper -->|construction: new| PayloadStore
  Woods__GemMapper -->|construction: new| Generation
  Woods__GemMapper -->|construction: new| PayloadStore
  Woods__GemMapSource(["new"])
  Woods__GemMapSource -->|construction: new| DependencyGraph
  Woods__GemMapSource -->|construction: new| ExtractedUnit
  Woods__GemMapSource -->|construction: new| Pathname
  Woods__GemMapPublisher(["to_h"])
  Woods__GemMapPublisher -->|serialization: to_h| unit
  Woods__GemMapPublisher -->|serialization: to_h| _graph
  Woods__GemMapPublisher -->|construction: new| GraphAnalyzer
  Woods__GemMapPublisher -->|serialization: to_h| GemMapper__TYPE_DIRECTORIES_keys
  Woods__GemMapPublisher -->|serialization: to_h| _graph
  Woods__GemMapper_initialize(["new"])
  Woods__GemMapper_initialize -->|construction: new| Pathname
  Woods__GemMapper_initialize -->|construction: new| Pathname
  Woods__GemMapper_map_(["new"])
  Woods__GemMapper_map_ -->|construction: new| GemMapSource
  Woods__GemMapper_map_ -->|construction: new| GemMapPublisher
  Woods__GemMapper_with_lock(["new"])
  Woods__GemMapper_with_lock -->|construction: new| Coordination__PipelineLock
  Woods__GemMapper_source_snapshot[/"serialization"/]
  Woods__GemMapper_source_snapshot -->|serialization: to_h| source_files
  Woods__GemMapper_checksum_for(["new"])
  Woods__GemMapper_checksum_for -->|construction: new| Digest__SHA256
  Woods__GemMapper_current_generation(["new"])
  Woods__GemMapper_current_generation -->|construction: new| Generation
  Woods__GemMapper_current_checksum(["new"])
  Woods__GemMapper_current_checksum -->|construction: new| Generation
  Woods__GemMapper_current_checksum -->|deserialization: parse| JSON
  Woods__GemMapper_relative_path(["new"])
  Woods__GemMapper_relative_path -->|construction: new| Pathname
  Woods__GemMapper_create_payload(["new"])
  Woods__GemMapper_create_payload -->|construction: new| PayloadStore
  Woods__GemMapper_publish_generation(["new"])
  Woods__GemMapper_publish_generation -->|construction: new| Generation
  Woods__GemMapper_publish_generation -->|construction: new| PayloadStore
  Woods__GemMapSource_build(["new"])
  Woods__GemMapSource_build -->|construction: new| DependencyGraph
  Woods__GemMapSource_file_units(["new"])
  Woods__GemMapSource_file_units -->|construction: new| ExtractedUnit
  Woods__GemMapSource_relative_path(["new"])
  Woods__GemMapSource_relative_path -->|construction: new| Pathname
  Woods__GemMapPublisher_write_type[/"serialization"/]
  Woods__GemMapPublisher_write_type -->|serialization: to_h| unit
  Woods__GemMapPublisher_write_graph(["to_h"])
  Woods__GemMapPublisher_write_graph -->|serialization: to_h| _graph
  Woods__GemMapPublisher_write_graph -->|construction: new| GraphAnalyzer
  Woods__GemMapPublisher_write_manifest[/"serialization"/]
  Woods__GemMapPublisher_write_manifest -->|serialization: to_h| GemMapper__TYPE_DIRECTORIES_keys
  Woods__GemMapPublisher_write_summary[/"serialization"/]
  Woods__GemMapPublisher_write_summary -->|serialization: to_h| _graph
  Woods -->|construction: new| Struct
  Marker["Marker"]
  Woods -->|construction: new| Marker
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| Marker
  Woods -->|construction: new| Marker
  marker["marker"]
  Woods -->|serialization: to_h| marker
  Woods -->|construction: new| Pathname
  Woods__Generation -->|construction: new| Struct
  Woods__Generation -->|construction: new| Marker
  Woods__Generation -->|deserialization: parse| JSON
  Woods__Generation -->|construction: new| Marker
  Woods__Generation -->|construction: new| Marker
  Woods__Generation -->|serialization: to_h| marker
  Woods__Generation -->|construction: new| Pathname
  Woods__Generation_current(["parse"])
  Woods__Generation_current -->|deserialization: parse| JSON
  Woods__Generation_current -->|construction: new| Marker
  Woods__Generation_bump_(["new"])
  Woods__Generation_bump_ -->|construction: new| Marker
  Woods__Generation_bump_ -->|serialization: to_h| marker
  Woods__Generation_root(["new"])
  Woods__Generation_root -->|construction: new| Pathname
  Woods -->|construction: new| Hash
  Woods -->|construction: new| Random
  Woods -->|construction: new| Hash
  Woods -->|construction: new| Hash
  Woods -->|construction: new| Set
  entry_points["entry_points"]
  Woods -->|serialization: to_a| entry_points
  Woods -->|construction: new| Hash
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
  Woods__GraphAnalyzer -->|construction: new| Hash
  Woods__GraphAnalyzer -->|construction: new| Hash
  Woods__GraphAnalyzer -->|construction: new| Set
  Woods__GraphAnalyzer -->|serialization: to_a| entry_points
  Woods__GraphAnalyzer -->|construction: new| Hash
  Woods__GraphAnalyzer -->|serialization: to_h| _graph
  Woods__GraphAnalyzer -->|construction: new| Hash
  Woods__GraphAnalyzer -->|construction: new| Set
  Woods__GraphAnalyzer -->|construction: new| Set
  Woods__GraphAnalyzer -->|serialization: to_a| pairs
  Woods__GraphAnalyzer -->|construction: new| Set
  Woods__GraphAnalyzer_bridges(["new"])
  Woods__GraphAnalyzer_bridges -->|construction: new| Hash
  Woods__GraphAnalyzer_bridges -->|construction: new| Random
  Woods__GraphAnalyzer_find_most_connected_cluster(["new"])
  Woods__GraphAnalyzer_find_most_connected_cluster -->|construction: new| Hash
  Woods__GraphAnalyzer_find_merge_target(["new"])
  Woods__GraphAnalyzer_find_merge_target -->|construction: new| Hash
  Woods__GraphAnalyzer_enrich_clusters(["new"])
  Woods__GraphAnalyzer_enrich_clusters -->|construction: new| Set
  Woods__GraphAnalyzer_enrich_clusters -->|serialization: to_a| entry_points
  Woods__GraphAnalyzer_enrich_clusters -->|construction: new| Hash
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
  Woods -->|construction: new| Pathname
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| Pathname
  Woods -->|construction: new| Tempfile
  Woods__IndexArtifact(["new"])
  Woods__IndexArtifact -->|construction: new| Pathname
  Woods__IndexArtifact -->|construction: new| Pathname
  Woods__IndexArtifact -->|deserialization: parse| JSON
  Woods__IndexArtifact -->|deserialization: parse| JSON
  Woods__IndexArtifact -->|construction: new| Pathname
  Woods__IndexArtifact -->|construction: new| Tempfile
  Woods__IndexArtifact_initialize(["new"])
  Woods__IndexArtifact_initialize -->|construction: new| Pathname
  Woods__IndexArtifact_dump_config_path(["new"])
  Woods__IndexArtifact_dump_config_path -->|construction: new| Pathname
  Woods__IndexArtifact_read_config[\"deserialization"\]
  Woods__IndexArtifact_read_config -->|deserialization: parse| JSON
  Woods__IndexArtifact_read_config -->|deserialization: parse| JSON
  Woods__IndexArtifact_validate_dump_dir_(["new"])
  Woods__IndexArtifact_validate_dump_dir_ -->|construction: new| Pathname
  Woods__IndexArtifact_atomic_write(["new"])
  Woods__IndexArtifact_atomic_write -->|construction: new| Tempfile
  __jsonrpc___2_0___error____code___32_001__message___Unauthorized_____id__nil__["{ jsonrpc: '2.0', error: { code: -32_001, message: 'Unauthorized' }, id: nil }"]
  Woods -->|serialization: to_json| __jsonrpc___2_0___error____code___32_001__message___Unauthorized_____id__nil__
  Woods__MCP[/"serialization"/]
  Woods__MCP -->|serialization: to_json| __jsonrpc___2_0___error____code___32_001__message___Unauthorized_____id__nil__
  Woods__MCP__BearerAuth[/"serialization"/]
  Woods__MCP__BearerAuth -->|serialization: to_json| __jsonrpc___2_0___error____code___32_001__message___Unauthorized_____id__nil__
  Woods -->|construction: new| Woods__Generation
  Woods -->|construction: new| SQLite3__Database
  Woods -->|construction: new| Woods__Db__Migrator
  Woods__Temporal__SnapshotStore["Woods::Temporal::SnapshotStore"]
  Woods -->|construction: new| Woods__Temporal__SnapshotStore
  Woods__Temporal__JsonSnapshotStore["Woods::Temporal::JsonSnapshotStore"]
  Woods -->|construction: new| Woods__Temporal__JsonSnapshotStore
  BootstrapState["BootstrapState"]
  Woods -->|construction: new| BootstrapState
  Woods__Error["Woods::Error"]
  Woods -->|construction: new| Woods__Error
  Woods -->|construction: new| Woods__Generation
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| Woods__Generation
  ReloadDegraded["ReloadDegraded"]
  Woods -->|construction: new| ReloadDegraded
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| ReloadDegraded
  Woods -->|construction: new| Struct
  ReloadCandidates["ReloadCandidates"]
  Woods -->|construction: new| ReloadCandidates
  Woods -->|construction: new| ReloadDegraded
  Woods -->|construction: new| ReloadDegraded
  Woods -->|construction: new| ReloadDegraded
  Woods -->|construction: new| ReloadDegraded
  ReloadGenerationMoved["ReloadGenerationMoved"]
  Woods -->|construction: new| ReloadGenerationMoved
  ReloadDumpMoved["ReloadDumpMoved"]
  Woods -->|construction: new| ReloadDumpMoved
  Woods -->|construction: new| Woods__Coordination__PipelineLock
  Woods -->|construction: new| Woods__Builder
  Woods -->|construction: new| IndexArtifact
  Woods -->|construction: new| Woods__Builder
  Woods -->|construction: new| Woods__Generation
  Woods -->|construction: new| Woods__Builder
  Woods -->|deserialization: parse| JSON
  Woods__Storage__GraphStore__Memory["Woods::Storage::GraphStore::Memory"]
  Woods -->|construction: new| Woods__Storage__GraphStore__Memory
  Woods -->|construction: new| Woods__Builder
  Woods__MCP -->|construction: new| Woods__Generation
  Woods__MCP -->|construction: new| SQLite3__Database
  Woods__MCP -->|construction: new| Woods__Db__Migrator
  Woods__MCP -->|construction: new| Woods__Temporal__SnapshotStore
  Woods__MCP -->|construction: new| Woods__Temporal__JsonSnapshotStore
  Woods__MCP -->|construction: new| BootstrapState
  Woods__MCP -->|construction: new| Woods__Error
  Woods__MCP -->|construction: new| Woods__Generation
  Woods__MCP -->|deserialization: parse| JSON
  Woods__MCP -->|construction: new| Woods__Generation
  Woods__MCP -->|construction: new| ReloadDegraded
  Woods__MCP -->|deserialization: parse| JSON
  Woods__MCP -->|deserialization: parse| JSON
  Woods__MCP -->|construction: new| ReloadDegraded
  Woods__MCP -->|construction: new| Struct
  Woods__MCP -->|construction: new| ReloadCandidates
  Woods__MCP -->|construction: new| ReloadDegraded
  Woods__MCP -->|construction: new| ReloadDegraded
  Woods__MCP -->|construction: new| ReloadDegraded
  Woods__MCP -->|construction: new| ReloadDegraded
  Woods__MCP -->|construction: new| ReloadGenerationMoved
  Woods__MCP -->|construction: new| ReloadDumpMoved
  Woods__MCP -->|construction: new| Woods__Coordination__PipelineLock
  Woods__MCP -->|construction: new| Woods__Builder
  Woods__MCP -->|construction: new| IndexArtifact
  Woods__MCP -->|construction: new| Woods__Builder
  Woods__MCP -->|construction: new| Woods__Generation
  Woods__MCP -->|construction: new| Woods__Builder
  Woods__MCP -->|deserialization: parse| JSON
  Woods__MCP -->|construction: new| Woods__Storage__GraphStore__Memory
  Woods__MCP -->|construction: new| Woods__Builder
  Woods__MCP__Bootstrapper(["new"])
  Woods__MCP__Bootstrapper -->|construction: new| Woods__Generation
  Woods__MCP__Bootstrapper -->|construction: new| SQLite3__Database
  Woods__MCP__Bootstrapper -->|construction: new| Woods__Db__Migrator
  Woods__MCP__Bootstrapper -->|construction: new| Woods__Temporal__SnapshotStore
  Woods__MCP__Bootstrapper -->|construction: new| Woods__Temporal__JsonSnapshotStore
  Woods__MCP__Bootstrapper -->|construction: new| BootstrapState
  Woods__MCP__Bootstrapper -->|construction: new| Woods__Error
  Woods__MCP__Bootstrapper -->|construction: new| Woods__Generation
  Woods__MCP__Bootstrapper -->|deserialization: parse| JSON
  Woods__MCP__Bootstrapper -->|construction: new| Woods__Generation
  Woods__MCP__Bootstrapper -->|construction: new| ReloadDegraded
  Woods__MCP__Bootstrapper -->|deserialization: parse| JSON
  Woods__MCP__Bootstrapper -->|deserialization: parse| JSON
  Woods__MCP__Bootstrapper -->|construction: new| ReloadDegraded
  Woods__MCP__Bootstrapper -->|construction: new| Struct
  Woods__MCP__Bootstrapper -->|construction: new| ReloadCandidates
  Woods__MCP__Bootstrapper -->|construction: new| ReloadDegraded
  Woods__MCP__Bootstrapper -->|construction: new| ReloadDegraded
  Woods__MCP__Bootstrapper -->|construction: new| ReloadDegraded
  Woods__MCP__Bootstrapper -->|construction: new| ReloadDegraded
  Woods__MCP__Bootstrapper -->|construction: new| ReloadGenerationMoved
  Woods__MCP__Bootstrapper -->|construction: new| ReloadDumpMoved
  Woods__MCP__Bootstrapper -->|construction: new| Woods__Coordination__PipelineLock
  Woods__MCP__Bootstrapper -->|construction: new| Woods__Builder
  Woods__MCP__Bootstrapper -->|construction: new| IndexArtifact
  Woods__MCP__Bootstrapper -->|construction: new| Woods__Builder
  Woods__MCP__Bootstrapper -->|construction: new| Woods__Generation
  Woods__MCP__Bootstrapper -->|construction: new| Woods__Builder
  Woods__MCP__Bootstrapper -->|deserialization: parse| JSON
  Woods__MCP__Bootstrapper -->|construction: new| Woods__Storage__GraphStore__Memory
  Woods__MCP__Bootstrapper -->|construction: new| Woods__Builder
  Woods__MCP__Bootstrapper_manifest_present_(["new"])
  Woods__MCP__Bootstrapper_manifest_present_ -->|construction: new| Woods__Generation
  Woods__MCP__Bootstrapper_build_snapshot_store(["new"])
  Woods__MCP__Bootstrapper_build_snapshot_store -->|construction: new| SQLite3__Database
  Woods__MCP__Bootstrapper_build_snapshot_store -->|construction: new| Woods__Db__Migrator
  Woods__MCP__Bootstrapper_build_snapshot_store -->|construction: new| Woods__Temporal__SnapshotStore
  Woods__MCP__Bootstrapper_build_snapshot_store -->|construction: new| Woods__Temporal__JsonSnapshotStore
  Woods__MCP__Bootstrapper_build_retriever(["new"])
  Woods__MCP__Bootstrapper_build_retriever -->|construction: new| BootstrapState
  Woods__MCP__Bootstrapper_build_retriever -->|construction: new| Woods__Error
  Woods__MCP__Bootstrapper_static_source_map_without_embeddings_(["new"])
  Woods__MCP__Bootstrapper_static_source_map_without_embeddings_ -->|construction: new| Woods__Generation
  Woods__MCP__Bootstrapper_static_source_map_without_embeddings_ -->|deserialization: parse| JSON
  Woods__MCP__Bootstrapper_reload_stores_(["new"])
  Woods__MCP__Bootstrapper_reload_stores_ -->|construction: new| Woods__Generation
  Woods__MCP__Bootstrapper_reload_stores_ -->|construction: new| ReloadDegraded
  Woods__MCP__Bootstrapper_captured_stored_config[\"deserialization"\]
  Woods__MCP__Bootstrapper_captured_stored_config -->|deserialization: parse| JSON
  Woods__MCP__Bootstrapper_captured_stored_config -->|deserialization: parse| JSON
  Woods__MCP__Bootstrapper_assert_dump_stores_refreshable_(["new"])
  Woods__MCP__Bootstrapper_assert_dump_stores_refreshable_ -->|construction: new| ReloadDegraded
  Woods__MCP__Bootstrapper_build_reload_candidates(["new"])
  Woods__MCP__Bootstrapper_build_reload_candidates -->|construction: new| ReloadCandidates
  Woods__MCP__Bootstrapper_reload_vector_candidate(["new"])
  Woods__MCP__Bootstrapper_reload_vector_candidate -->|construction: new| ReloadDegraded
  Woods__MCP__Bootstrapper_reload_metadata_candidate(["new"])
  Woods__MCP__Bootstrapper_reload_metadata_candidate -->|construction: new| ReloadDegraded
  Woods__MCP__Bootstrapper_reload_graph_candidate(["new"])
  Woods__MCP__Bootstrapper_reload_graph_candidate -->|construction: new| ReloadDegraded
  Woods__MCP__Bootstrapper_commit_reload_(["new"])
  Woods__MCP__Bootstrapper_commit_reload_ -->|construction: new| ReloadDegraded
  Woods__MCP__Bootstrapper_commit_reload_ -->|construction: new| ReloadGenerationMoved
  Woods__MCP__Bootstrapper_commit_reload_ -->|construction: new| ReloadDumpMoved
  Woods__MCP__Bootstrapper_reload_extraction_lock(["new"])
  Woods__MCP__Bootstrapper_reload_extraction_lock -->|construction: new| Woods__Coordination__PipelineLock
  Woods__MCP__Bootstrapper_build_resolved_config(["new"])
  Woods__MCP__Bootstrapper_build_resolved_config -->|construction: new| Woods__Builder
  Woods__MCP__Bootstrapper_build_artifact(["new"])
  Woods__MCP__Bootstrapper_build_artifact -->|construction: new| IndexArtifact
  Woods__MCP__Bootstrapper_build_retriever_from_config(["new"])
  Woods__MCP__Bootstrapper_build_retriever_from_config -->|construction: new| Woods__Builder
  Woods__MCP__Bootstrapper_hydrated_graph_store(["new"])
  Woods__MCP__Bootstrapper_hydrated_graph_store -->|construction: new| Woods__Generation
  Woods__MCP__Bootstrapper_hydrated_graph_store -->|construction: new| Woods__Builder
  Woods__MCP__Bootstrapper_hydrated_graph_store -->|deserialization: parse| JSON
  Woods__MCP__Bootstrapper_hydrated_graph_store -->|construction: new| Woods__Storage__GraphStore__Memory
  Woods__MCP__Bootstrapper_probe_and_mark_state(["new"])
  Woods__MCP__Bootstrapper_probe_and_mark_state -->|construction: new| Woods__Builder
  Woods -->|construction: new| Woods__Builder
  Woods__MCP__MissingCredential["Woods::MCP::MissingCredential"]
  Woods -->|construction: new| Woods__MCP__MissingCredential
  MissingArtifact["MissingArtifact"]
  Woods -->|construction: new| MissingArtifact
  URI["URI"]
  Woods -->|deserialization: parse| URI
  Woods__MCP -->|construction: new| Woods__Builder
  Woods__MCP -->|construction: new| Woods__MCP__MissingCredential
  Woods__MCP -->|construction: new| MissingArtifact
  Woods__MCP -->|deserialization: parse| URI
  Woods__MCP__ConfigResolver(["new"])
  Woods__MCP__ConfigResolver -->|construction: new| Woods__Builder
  Woods__MCP__ConfigResolver -->|construction: new| Woods__MCP__MissingCredential
  Woods__MCP__ConfigResolver -->|construction: new| MissingArtifact
  Woods__MCP__ConfigResolver -->|deserialization: parse| URI
  Woods__MCP__ConfigResolver_live_resolved_config(["new"])
  Woods__MCP__ConfigResolver_live_resolved_config -->|construction: new| Woods__Builder
  Woods__MCP__ConfigResolver_populate_from_stored(["new"])
  Woods__MCP__ConfigResolver_populate_from_stored -->|construction: new| Woods__MCP__MissingCredential
  Woods__MCP__ConfigResolver_resolve_without_artifact(["new"])
  Woods__MCP__ConfigResolver_resolve_without_artifact -->|construction: new| MissingArtifact
  Woods__MCP__ConfigResolver_ollama_reachable_[\"deserialization"\]
  Woods__MCP__ConfigResolver_ollama_reachable_ -->|deserialization: parse| URI
  TYPE_DIRS["TYPE_DIRS"]
  Woods -->|serialization: to_h| TYPE_DIRS
  Woods -->|construction: new| Pathname
  Woods -->|construction: new| Hash
  Woods -->|construction: new| Mutex
  Woods -->|construction: new| ConditionVariable
  Woods -->|construction: new| Mutex
  Woods -->|construction: new| Woods__Generation
  unit___["unit.[]"]
  Woods -->|serialization: to_json| unit___
  Woods -->|construction: new| Regexp
  Woods -->|serialization: to_json| unit___
  Woods -->|construction: new| Woods__Generation
  Woods -->|construction: new| Woods__Generation
  Gem__Version["Gem::Version"]
  Woods -->|construction: new| Gem__Version
  Woods -->|construction: new| Gem__Version
  Woods -->|construction: new| Regexp
  Woods -->|construction: new| Regexp
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| Set
  Woods__MCP -->|serialization: to_h| TYPE_DIRS
  Woods__MCP -->|construction: new| Pathname
  Woods__MCP -->|construction: new| Hash
  Woods__MCP -->|construction: new| Mutex
  Woods__MCP -->|construction: new| ConditionVariable
  Woods__MCP -->|construction: new| Mutex
  Woods__MCP -->|construction: new| Woods__Generation
  Woods__MCP -->|serialization: to_json| unit___
  Woods__MCP -->|construction: new| Regexp
  Woods__MCP -->|serialization: to_json| unit___
  Woods__MCP -->|construction: new| Woods__Generation
  Woods__MCP -->|construction: new| Woods__Generation
  Woods__MCP -->|construction: new| Gem__Version
  Woods__MCP -->|construction: new| Gem__Version
  Woods__MCP -->|construction: new| Regexp
  Woods__MCP -->|construction: new| Regexp
  Woods__MCP -->|deserialization: parse| JSON
  Woods__MCP -->|deserialization: parse| JSON
  Woods__MCP -->|deserialization: parse| JSON
  Woods__MCP -->|construction: new| Set
  Woods__MCP__IndexReader(["to_h"])
  Woods__MCP__IndexReader -->|serialization: to_h| TYPE_DIRS
  Woods__MCP__IndexReader -->|construction: new| Pathname
  Woods__MCP__IndexReader -->|construction: new| Hash
  Woods__MCP__IndexReader -->|construction: new| Mutex
  Woods__MCP__IndexReader -->|construction: new| ConditionVariable
  Woods__MCP__IndexReader -->|construction: new| Mutex
  Woods__MCP__IndexReader -->|construction: new| Woods__Generation
  Woods__MCP__IndexReader -->|serialization: to_json| unit___
  Woods__MCP__IndexReader -->|construction: new| Regexp
  Woods__MCP__IndexReader -->|serialization: to_json| unit___
  Woods__MCP__IndexReader -->|construction: new| Woods__Generation
  Woods__MCP__IndexReader -->|construction: new| Woods__Generation
  Woods__MCP__IndexReader -->|construction: new| Gem__Version
  Woods__MCP__IndexReader -->|construction: new| Gem__Version
  Woods__MCP__IndexReader -->|construction: new| Regexp
  Woods__MCP__IndexReader -->|construction: new| Regexp
  Woods__MCP__IndexReader -->|deserialization: parse| JSON
  Woods__MCP__IndexReader -->|deserialization: parse| JSON
  Woods__MCP__IndexReader -->|deserialization: parse| JSON
  Woods__MCP__IndexReader -->|construction: new| Set
  Woods__MCP__IndexReader_initialize(["new"])
  Woods__MCP__IndexReader_initialize -->|construction: new| Pathname
  Woods__MCP__IndexReader_initialize -->|construction: new| Hash
  Woods__MCP__IndexReader_initialize -->|construction: new| Mutex
  Woods__MCP__IndexReader_initialize -->|construction: new| ConditionVariable
  Woods__MCP__IndexReader_initialize -->|construction: new| Mutex
  Woods__MCP__IndexReader_initialize -->|construction: new| Woods__Generation
  Woods__MCP__IndexReader_search_within_pin[/"serialization"/]
  Woods__MCP__IndexReader_search_within_pin -->|serialization: to_json| unit___
  Woods__MCP__IndexReader_framework_sources_within_pin(["new"])
  Woods__MCP__IndexReader_framework_sources_within_pin -->|construction: new| Regexp
  Woods__MCP__IndexReader_framework_sources_within_pin -->|serialization: to_json| unit___
  Woods__MCP__IndexReader_manifest_present_(["new"])
  Woods__MCP__IndexReader_manifest_present_ -->|construction: new| Woods__Generation
  Woods__MCP__IndexReader_resolve_payload_dir(["new"])
  Woods__MCP__IndexReader_resolve_payload_dir -->|construction: new| Woods__Generation
  Woods__MCP__IndexReader_compile_case_insensitive_pattern(["new"])
  Woods__MCP__IndexReader_compile_case_insensitive_pattern -->|construction: new| Gem__Version
  Woods__MCP__IndexReader_compile_case_insensitive_pattern -->|construction: new| Gem__Version
  Woods__MCP__IndexReader_compile_case_insensitive_pattern -->|construction: new| Regexp
  Woods__MCP__IndexReader_compile_case_insensitive_pattern -->|construction: new| Regexp
  Woods__MCP__IndexReader_read_index[\"deserialization"\]
  Woods__MCP__IndexReader_read_index -->|deserialization: parse| JSON
  Woods__MCP__IndexReader_load_unit[\"deserialization"\]
  Woods__MCP__IndexReader_load_unit -->|deserialization: parse| JSON
  Woods__MCP__IndexReader_parse_json[\"deserialization"\]
  Woods__MCP__IndexReader_parse_json -->|deserialization: parse| JSON
  Woods__MCP__IndexReader_traverse(["new"])
  Woods__MCP__IndexReader_traverse -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods__MCP -->|construction: new| Set
  Woods__MCP__IndexReaderPinning(["new"])
  Woods__MCP__IndexReaderPinning -->|construction: new| Set
  __jsonrpc___2_0___error____code___32_002__message___Origin_not_allowed_____id__nil__["{ jsonrpc: '2.0', error: { code: -32_002, message: 'Origin not allowed' }, id: nil }"]
  Woods -->|serialization: to_json| __jsonrpc___2_0___error____code___32_002__message___Origin_not_allowed_____id__nil__
  __jsonrpc___2_0___error____code___32_002__message___Host_not_allowed_____id__nil__["{ jsonrpc: '2.0', error: { code: -32_002, message: 'Host not allowed' }, id: nil }"]
  Woods -->|serialization: to_json| __jsonrpc___2_0___error____code___32_002__message___Host_not_allowed_____id__nil__
  Woods__MCP -->|serialization: to_json| __jsonrpc___2_0___error____code___32_002__message___Origin_not_allowed_____id__nil__
  Woods__MCP -->|serialization: to_json| __jsonrpc___2_0___error____code___32_002__message___Host_not_allowed_____id__nil__
  Woods__MCP__OriginGuard[/"serialization"/]
  Woods__MCP__OriginGuard -->|serialization: to_json| __jsonrpc___2_0___error____code___32_002__message___Origin_not_allowed_____id__nil__
  Woods__MCP__OriginGuard -->|serialization: to_json| __jsonrpc___2_0___error____code___32_002__message___Host_not_allowed_____id__nil__
  tools_sort_by["tools.sort_by"]
  Woods -->|serialization: to_h| tools_sort_by
  Woods__MCP -->|serialization: to_h| tools_sort_by
  Woods__MCP__ProtocolPolicy[/"serialization"/]
  Woods__MCP__ProtocolPolicy -->|serialization: to_h| tools_sort_by
  Woods -->|deserialization: parse| URI
  Woods__MCP__ProviderUnreachable["Woods::MCP::ProviderUnreachable"]
  Woods -->|construction: new| Woods__MCP__ProviderUnreachable
  Woods -->|construction: new| Woods__MCP__ProviderUnreachable
  Woods -->|deserialization: parse| URI
  Woods -->|construction: new| Net__HTTP
  Woods -->|construction: new| Woods__MCP__ProviderUnreachable
  Woods__MCP -->|deserialization: parse| URI
  Woods__MCP -->|construction: new| Woods__MCP__ProviderUnreachable
  Woods__MCP -->|construction: new| Woods__MCP__ProviderUnreachable
  Woods__MCP -->|deserialization: parse| URI
  Woods__MCP -->|construction: new| Net__HTTP
  Woods__MCP -->|construction: new| Woods__MCP__ProviderUnreachable
  Woods__MCP__ProviderProbe(["parse"])
  Woods__MCP__ProviderProbe -->|deserialization: parse| URI
  Woods__MCP__ProviderProbe -->|construction: new| Woods__MCP__ProviderUnreachable
  Woods__MCP__ProviderProbe -->|construction: new| Woods__MCP__ProviderUnreachable
  Woods__MCP__ProviderProbe -->|deserialization: parse| URI
  Woods__MCP__ProviderProbe -->|construction: new| Net__HTTP
  Woods__MCP__ProviderProbe -->|construction: new| Woods__MCP__ProviderUnreachable
  Woods__MCP__ProviderProbe_probe_ollama_(["parse"])
  Woods__MCP__ProviderProbe_probe_ollama_ -->|deserialization: parse| URI
  Woods__MCP__ProviderProbe_probe_ollama_ -->|construction: new| Woods__MCP__ProviderUnreachable
  Woods__MCP__ProviderProbe_probe_openai_(["new"])
  Woods__MCP__ProviderProbe_probe_openai_ -->|construction: new| Woods__MCP__ProviderUnreachable
  Woods__MCP__ProviderProbe_http_get_(["parse"])
  Woods__MCP__ProviderProbe_http_get_ -->|deserialization: parse| URI
  Woods__MCP__ProviderProbe_http_get_ -->|construction: new| Net__HTTP
  Woods__MCP__ProviderProbe_http_get_ -->|construction: new| Woods__MCP__ProviderUnreachable
  Woods -->|construction: new| Mutex
  IndexReader["IndexReader"]
  Woods -->|construction: new| IndexReader
  Woods -->|construction: new| MCP__Server
  MCP__Configuration["MCP::Configuration"]
  Woods -->|construction: new| MCP__Configuration
  Tasks__Store["Tasks::Store"]
  Woods -->|construction: new| Tasks__Store
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| MCP__Tool__Response
  Woods -->|construction: new| MCP__Tool__Response
  Woods -->|construction: new| MCP__Tool__Response
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| Woods__GraphAnalyzer
  Woods -->|construction: new| Woods__FlowAssembler
  flow_doc["flow_doc"]
  Woods -->|serialization: to_h| flow_doc
  Woods__SessionTracer__SessionFlowAssembler["Woods::SessionTracer::SessionFlowAssembler"]
  Woods -->|construction: new| Woods__SessionTracer__SessionFlowAssembler
  Woods -->|construction: new| Woods__Extractor
  Woods -->|construction: new| Woods__Coordination__PipelineLock
  Woods -->|construction: new| Thread
  Woods -->|construction: new| Logger
  StandardError["StandardError"]
  Woods -->|construction: new| StandardError
  Woods -->|construction: new| Woods__Feedback__GapDetector
  Woods__Notion__Exporter["Woods::Notion::Exporter"]
  Woods -->|construction: new| Woods__Notion__Exporter
  MCP__ResourceTemplate["MCP::ResourceTemplate"]
  Woods -->|construction: new| MCP__ResourceTemplate
  Woods -->|construction: new| MCP__ResourceTemplate
  MCP__Resource["MCP::Resource"]
  Woods -->|construction: new| MCP__Resource
  Woods -->|construction: new| MCP__Resource
  Woods__Configuration["Woods::Configuration"]
  Woods -->|construction: new| Woods__Configuration
  Woods -->|construction: new| Woods__Generation
  Woods -->|deserialization: parse| JSON
  Woods__Watch__Status["Woods::Watch::Status"]
  Woods -->|construction: new| Woods__Watch__Status
  Time["Time"]
  Woods -->|deserialization: parse| Time
  MCP__Server__ResourceNotFoundError["MCP::Server::ResourceNotFoundError"]
  Woods -->|construction: new| MCP__Server__ResourceNotFoundError
  Woods -->|construction: new| MCP__Server__ResourceNotFoundError
  Woods -->|deserialization: parse| URI
  MCP__Server__RequestHandlerError["MCP::Server::RequestHandlerError"]
  Woods -->|construction: new| MCP__Server__RequestHandlerError
  Woods__MCP -->|construction: new| Mutex
  Woods__MCP -->|construction: new| IndexReader
  Woods__MCP -->|construction: new| MCP__Server
  Woods__MCP -->|construction: new| MCP__Configuration
  Woods__MCP -->|construction: new| Tasks__Store
  Woods__MCP -->|deserialization: parse| JSON
  Woods__MCP -->|construction: new| MCP__Tool__Response
  Woods__MCP -->|construction: new| MCP__Tool__Response
  Woods__MCP -->|construction: new| MCP__Tool__Response
  Woods__MCP -->|deserialization: parse| JSON
  Woods__MCP -->|construction: new| Woods__GraphAnalyzer
  Woods__MCP -->|construction: new| Woods__FlowAssembler
  Woods__MCP -->|serialization: to_h| flow_doc
  Woods__MCP -->|construction: new| Woods__SessionTracer__SessionFlowAssembler
  Woods__MCP -->|construction: new| Woods__Extractor
  Woods__MCP -->|construction: new| Woods__Coordination__PipelineLock
  Woods__MCP -->|construction: new| Thread
  Woods__MCP -->|construction: new| Logger
  Woods__MCP -->|construction: new| StandardError
  Woods__MCP -->|construction: new| Woods__Feedback__GapDetector
  Woods__MCP -->|construction: new| Woods__Notion__Exporter
  Woods__MCP -->|construction: new| MCP__ResourceTemplate
  Woods__MCP -->|construction: new| MCP__ResourceTemplate
  Woods__MCP -->|construction: new| MCP__Resource
  Woods__MCP -->|construction: new| MCP__Resource
  Woods__MCP -->|construction: new| Woods__Configuration
  Woods__MCP -->|construction: new| Woods__Generation
  Woods__MCP -->|deserialization: parse| JSON
  Woods__MCP -->|construction: new| Woods__Watch__Status
  Woods__MCP -->|deserialization: parse| Time
  Woods__MCP -->|construction: new| MCP__Server__ResourceNotFoundError
  Woods__MCP -->|construction: new| MCP__Server__ResourceNotFoundError
  Woods__MCP -->|deserialization: parse| URI
  Woods__MCP -->|construction: new| MCP__Server__RequestHandlerError
  Woods__MCP__Server(["new"])
  Woods__MCP__Server -->|construction: new| Mutex
  Woods__MCP__Server -->|construction: new| IndexReader
  Woods__MCP__Server -->|construction: new| MCP__Server
  Woods__MCP__Server -->|construction: new| MCP__Configuration
  Woods__MCP__Server -->|construction: new| Tasks__Store
  Woods__MCP__Server -->|deserialization: parse| JSON
  Woods__MCP__Server -->|construction: new| MCP__Tool__Response
  Woods__MCP__Server -->|construction: new| MCP__Tool__Response
  Woods__MCP__Server -->|construction: new| MCP__Tool__Response
  Woods__MCP__Server -->|deserialization: parse| JSON
  Woods__MCP__Server -->|construction: new| Woods__GraphAnalyzer
  Woods__MCP__Server -->|construction: new| Woods__FlowAssembler
  Woods__MCP__Server -->|serialization: to_h| flow_doc
  Woods__MCP__Server -->|construction: new| Woods__SessionTracer__SessionFlowAssembler
  Woods__MCP__Server -->|construction: new| Woods__Extractor
  Woods__MCP__Server -->|construction: new| Woods__Coordination__PipelineLock
  Woods__MCP__Server -->|construction: new| Thread
  Woods__MCP__Server -->|construction: new| Logger
  Woods__MCP__Server -->|construction: new| StandardError
  Woods__MCP__Server -->|construction: new| Woods__Feedback__GapDetector
  Woods__MCP__Server -->|construction: new| Woods__Notion__Exporter
  Woods__MCP__Server -->|construction: new| MCP__ResourceTemplate
  Woods__MCP__Server -->|construction: new| MCP__ResourceTemplate
  Woods__MCP__Server -->|construction: new| MCP__Resource
  Woods__MCP__Server -->|construction: new| MCP__Resource
  Woods__MCP__Server -->|construction: new| Woods__Configuration
  Woods__MCP__Server -->|construction: new| Woods__Generation
  Woods__MCP__Server -->|deserialization: parse| JSON
  Woods__MCP__Server -->|construction: new| Woods__Watch__Status
  Woods__MCP__Server -->|deserialization: parse| Time
  Woods__MCP__Server -->|construction: new| MCP__Server__ResourceNotFoundError
  Woods__MCP__Server -->|construction: new| MCP__Server__ResourceNotFoundError
  Woods__MCP__Server -->|deserialization: parse| URI
  Woods__MCP__Server -->|construction: new| MCP__Server__RequestHandlerError
  task["task"]
  Woods -->|serialization: to_h| task
  Woods -->|construction: new| MCP__Server__RequestHandlerError
  Woods -->|serialization: to_h| task
  Woods -->|construction: new| MCP__Server__RequestHandlerError
  Woods -->|construction: new| MCP__Server__RequestHandlerError
  MCP__Server__MissingRequiredClientCapabilityError["MCP::Server::MissingRequiredClientCapabilityError"]
  Woods -->|construction: new| MCP__Server__MissingRequiredClientCapabilityError
  Woods -->|construction: new| MCP__Server__RequestHandlerError
  Woods__MCP -->|serialization: to_h| task
  Woods__MCP -->|construction: new| MCP__Server__RequestHandlerError
  Woods__MCP -->|serialization: to_h| task
  Woods__MCP -->|construction: new| MCP__Server__RequestHandlerError
  Woods__MCP -->|construction: new| MCP__Server__RequestHandlerError
  Woods__MCP -->|construction: new| MCP__Server__MissingRequiredClientCapabilityError
  Woods__MCP -->|construction: new| MCP__Server__RequestHandlerError
  Woods__MCP__Tasks(["to_h"])
  Woods__MCP__Tasks -->|serialization: to_h| task
  Woods__MCP__Tasks -->|construction: new| MCP__Server__RequestHandlerError
  Woods__MCP__Tasks -->|serialization: to_h| task
  Woods__MCP__Tasks -->|construction: new| MCP__Server__RequestHandlerError
  Woods__MCP__Tasks -->|construction: new| MCP__Server__RequestHandlerError
  Woods__MCP__Tasks -->|construction: new| MCP__Server__MissingRequiredClientCapabilityError
  Woods__MCP__Tasks -->|construction: new| MCP__Server__RequestHandlerError
  Woods__MCP__Tasks__Extension(["to_h"])
  Woods__MCP__Tasks__Extension -->|serialization: to_h| task
  Woods__MCP__Tasks__Extension -->|construction: new| MCP__Server__RequestHandlerError
  Woods__MCP__Tasks__Extension -->|serialization: to_h| task
  Woods__MCP__Tasks__Extension -->|construction: new| MCP__Server__RequestHandlerError
  Woods__MCP__Tasks__Extension -->|construction: new| MCP__Server__RequestHandlerError
  Woods__MCP__Tasks__Extension -->|construction: new| MCP__Server__MissingRequiredClientCapabilityError
  Woods__MCP__Tasks__Extension -->|construction: new| MCP__Server__RequestHandlerError
  Woods -->|construction: new| Struct
  each_pair["each_pair"]
  Woods -->|serialization: to_h| each_pair
  Task["Task"]
  Woods -->|construction: new| Task
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| Task
  Woods -->|deserialization: parse| Time
  Woods__MCP -->|construction: new| Struct
  Woods__MCP -->|serialization: to_h| each_pair
  Woods__MCP -->|construction: new| Task
  Woods__MCP -->|deserialization: parse| JSON
  Woods__MCP -->|construction: new| Task
  Woods__MCP -->|deserialization: parse| Time
  Woods__MCP__Tasks -->|construction: new| Struct
  Woods__MCP__Tasks -->|serialization: to_h| each_pair
  Woods__MCP__Tasks -->|construction: new| Task
  Woods__MCP__Tasks -->|deserialization: parse| JSON
  Woods__MCP__Tasks -->|construction: new| Task
  Woods__MCP__Tasks -->|deserialization: parse| Time
  Woods__MCP__Tasks__Store(["new"])
  Woods__MCP__Tasks__Store -->|construction: new| Struct
  Woods__MCP__Tasks__Store -->|serialization: to_h| each_pair
  Woods__MCP__Tasks__Store -->|construction: new| Task
  Woods__MCP__Tasks__Store -->|deserialization: parse| JSON
  Woods__MCP__Tasks__Store -->|construction: new| Task
  Woods__MCP__Tasks__Store -->|deserialization: parse| Time
  Woods__MCP__Tasks__Store_create_(["new"])
  Woods__MCP__Tasks__Store_create_ -->|construction: new| Task
  Woods__MCP__Tasks__Store_read(["parse"])
  Woods__MCP__Tasks__Store_read -->|deserialization: parse| JSON
  Woods__MCP__Tasks__Store_read -->|construction: new| Task
  Woods__MCP__Tasks__Store_expired_[\"deserialization"\]
  Woods__MCP__Tasks__Store_expired_ -->|deserialization: parse| Time
  tool_input_schema_value["tool.input_schema_value"]
  Woods -->|serialization: to_h| tool_input_schema_value
  Woods -->|deserialization: parse| JSON
  MCP__Tool__Response_new["MCP::Tool::Response.new"]
  Woods -->|serialization: to_h| MCP__Tool__Response_new
  Woods -->|construction: new| MCP__Tool__Response
  Woods__MCP -->|serialization: to_h| tool_input_schema_value
  Woods__MCP -->|deserialization: parse| JSON
  Woods__MCP -->|serialization: to_h| MCP__Tool__Response_new
  Woods__MCP -->|construction: new| MCP__Tool__Response
  Woods__MCP__ToolContract(["to_h"])
  Woods__MCP__ToolContract -->|serialization: to_h| tool_input_schema_value
  Woods__MCP__ToolContract -->|deserialization: parse| JSON
  Woods__MCP__ToolContract -->|serialization: to_h| MCP__Tool__Response_new
  Woods__MCP__ToolContract -->|construction: new| MCP__Tool__Response
  Woods__MCP__ToolContract__Dispatch(["to_h"])
  Woods__MCP__ToolContract__Dispatch -->|serialization: to_h| MCP__Tool__Response_new
  Woods__MCP__ToolContract__Dispatch -->|construction: new| MCP__Tool__Response
  Woods__MCP__ToolContract__Dispatch_contract_error(["to_h"])
  Woods__MCP__ToolContract__Dispatch_contract_error -->|serialization: to_h| MCP__Tool__Response_new
  Woods__MCP__ToolContract__Dispatch_contract_error -->|construction: new| MCP__Tool__Response
  Renderers__ClaudeRenderer["Renderers::ClaudeRenderer"]
  Woods -->|construction: new| Renderers__ClaudeRenderer
  Renderers__MarkdownRenderer["Renderers::MarkdownRenderer"]
  Woods -->|construction: new| Renderers__MarkdownRenderer
  Renderers__PlainRenderer["Renderers::PlainRenderer"]
  Woods -->|construction: new| Renderers__PlainRenderer
  Renderers__JsonRenderer["Renderers::JsonRenderer"]
  Woods -->|construction: new| Renderers__JsonRenderer
  Woods__MCP -->|construction: new| Renderers__ClaudeRenderer
  Woods__MCP -->|construction: new| Renderers__MarkdownRenderer
  Woods__MCP -->|construction: new| Renderers__PlainRenderer
  Woods__MCP -->|construction: new| Renderers__JsonRenderer
  Woods__MCP__ToolResponseRenderer(["new"])
  Woods__MCP__ToolResponseRenderer -->|construction: new| Renderers__ClaudeRenderer
  Woods__MCP__ToolResponseRenderer -->|construction: new| Renderers__MarkdownRenderer
  Woods__MCP__ToolResponseRenderer -->|construction: new| Renderers__PlainRenderer
  Woods__MCP__ToolResponseRenderer -->|construction: new| Renderers__JsonRenderer
  Woods__MCP__ToolResponseRenderer_for(["new"])
  Woods__MCP__ToolResponseRenderer_for -->|construction: new| Renderers__ClaudeRenderer
  Woods__MCP__ToolResponseRenderer_for -->|construction: new| Renderers__MarkdownRenderer
  Woods__MCP__ToolResponseRenderer_for -->|construction: new| Renderers__PlainRenderer
  Woods__MCP__ToolResponseRenderer_for -->|construction: new| Renderers__JsonRenderer
  Woods -->|construction: new| MCP__Server__RequestHandlerError
  Woods__MCP -->|construction: new| MCP__Server__RequestHandlerError
  Woods__MCP__VersionAwareToolDispatch(["new"])
  Woods__MCP__VersionAwareToolDispatch -->|construction: new| MCP__Server__RequestHandlerError
  Woods__MCP__VersionAwareToolDispatch_call_tool(["new"])
  Woods__MCP__VersionAwareToolDispatch_call_tool -->|construction: new| MCP__Server__RequestHandlerError
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| Net__HTTP
  Woods -->|construction: new| Net__HTTP__Post
  Net__HTTP__Patch["Net::HTTP::Patch"]
  Woods -->|construction: new| Net__HTTP__Patch
  Net__HTTP__Get["Net::HTTP::Get"]
  Woods -->|construction: new| Net__HTTP__Get
  Woods__Notion(["parse"])
  Woods__Notion -->|deserialization: parse| JSON
  Woods__Notion -->|deserialization: parse| JSON
  Woods__Notion -->|deserialization: parse| JSON
  Woods__Notion -->|construction: new| Net__HTTP
  Woods__Notion -->|construction: new| Net__HTTP__Post
  Woods__Notion -->|construction: new| Net__HTTP__Patch
  Woods__Notion -->|construction: new| Net__HTTP__Get
  Woods__Notion__Client(["parse"])
  Woods__Notion__Client -->|deserialization: parse| JSON
  Woods__Notion__Client -->|deserialization: parse| JSON
  Woods__Notion__Client -->|deserialization: parse| JSON
  Woods__Notion__Client -->|construction: new| Net__HTTP
  Woods__Notion__Client -->|construction: new| Net__HTTP__Post
  Woods__Notion__Client -->|construction: new| Net__HTTP__Patch
  Woods__Notion__Client -->|construction: new| Net__HTTP__Get
  Woods__Notion__Client_request[\"deserialization"\]
  Woods__Notion__Client_request -->|deserialization: parse| JSON
  Woods__Notion__Client_raise_ambiguous_response_error[\"deserialization"\]
  Woods__Notion__Client_raise_ambiguous_response_error -->|deserialization: parse| JSON
  Woods__Notion__Client_raise_api_error[\"deserialization"\]
  Woods__Notion__Client_raise_api_error -->|deserialization: parse| JSON
  Woods__Notion__Client_execute_http(["new"])
  Woods__Notion__Client_execute_http -->|construction: new| Net__HTTP
  Woods__Notion__Client_build_request(["new"])
  Woods__Notion__Client_build_request -->|construction: new| Net__HTTP__Post
  Woods__Notion__Client_build_request -->|construction: new| Net__HTTP__Patch
  Woods__Notion__Client_build_request -->|construction: new| Net__HTTP__Get
  Client["Client"]
  Woods -->|construction: new| Client
  Mappers__ModelMapper["Mappers::ModelMapper"]
  Woods -->|construction: new| Mappers__ModelMapper
  Mappers__ColumnMapper["Mappers::ColumnMapper"]
  Woods -->|construction: new| Mappers__ColumnMapper
  Mappers__MigrationMapper["Mappers::MigrationMapper"]
  Woods -->|construction: new| Mappers__MigrationMapper
  Woods -->|construction: new| Hash
  SyncManifest["SyncManifest"]
  Woods -->|construction: new| SyncManifest
  Woods -->|construction: new| Woods__MCP__IndexReader
  Woods__Notion -->|construction: new| Client
  Woods__Notion -->|construction: new| Mappers__ModelMapper
  Woods__Notion -->|construction: new| Mappers__ColumnMapper
  Woods__Notion -->|construction: new| Mappers__MigrationMapper
  Woods__Notion -->|construction: new| Hash
  Woods__Notion -->|construction: new| SyncManifest
  Woods__Notion -->|construction: new| Woods__MCP__IndexReader
  Woods__Notion__Exporter -->|construction: new| Client
  Woods__Notion__Exporter -->|construction: new| Mappers__ModelMapper
  Woods__Notion__Exporter -->|construction: new| Mappers__ColumnMapper
  Woods__Notion__Exporter -->|construction: new| Mappers__MigrationMapper
  Woods__Notion__Exporter -->|construction: new| Hash
  Woods__Notion__Exporter -->|construction: new| SyncManifest
  Woods__Notion__Exporter -->|construction: new| Woods__MCP__IndexReader
  Woods__Notion__Exporter_initialize(["new"])
  Woods__Notion__Exporter_initialize -->|construction: new| Client
  Woods__Notion__Exporter_sync_data_models(["new"])
  Woods__Notion__Exporter_sync_data_models -->|construction: new| Mappers__ModelMapper
  Woods__Notion__Exporter_sync_table_columns(["new"])
  Woods__Notion__Exporter_sync_table_columns -->|construction: new| Mappers__ColumnMapper
  Woods__Notion__Exporter_load_migration_dates(["new"])
  Woods__Notion__Exporter_load_migration_dates -->|construction: new| Mappers__MigrationMapper
  Woods__Notion__Exporter_shared_table_names(["new"])
  Woods__Notion__Exporter_shared_table_names -->|construction: new| Hash
  Woods__Notion__Exporter_build_manifest(["new"])
  Woods__Notion__Exporter_build_manifest -->|construction: new| SyncManifest
  Woods__Notion__Exporter_build_reader(["new"])
  Woods__Notion__Exporter_build_reader -->|construction: new| Woods__MCP__IndexReader
  Woods__Console__CredentialScanner["Woods::Console::CredentialScanner"]
  Woods -->|construction: new| Woods__Console__CredentialScanner
  Woods__Notion -->|construction: new| Woods__Console__CredentialScanner
  Woods__Notion__Mappers(["new"])
  Woods__Notion__Mappers -->|construction: new| Woods__Console__CredentialScanner
  Woods__Notion__Mappers__ModelMapper(["new"])
  Woods__Notion__Mappers__ModelMapper -->|construction: new| Woods__Console__CredentialScanner
  Woods__Notion__Mappers__ModelMapper_scanner(["new"])
  Woods__Notion__Mappers__ModelMapper_scanner -->|construction: new| Woods__Console__CredentialScanner
  Woods -->|construction: new| Mutex
  Woods__Notion -->|construction: new| Mutex
  Woods__Notion__RateLimiter(["new"])
  Woods__Notion__RateLimiter -->|construction: new| Mutex
  Woods__Notion__RateLimiter_initialize(["new"])
  Woods__Notion__RateLimiter_initialize -->|construction: new| Mutex
  value_map_sort_by["value.map.sort_by"]
  Woods -->|serialization: to_h| value_map_sort_by
  current_keys["current_keys"]
  Woods -->|serialization: to_a| current_keys
  Woods -->|deserialization: parse| JSON
  Woods__Notion -->|serialization: to_h| value_map_sort_by
  Woods__Notion -->|serialization: to_a| current_keys
  Woods__Notion -->|deserialization: parse| JSON
  Woods__Notion__SyncManifest[/"serialization"/]
  Woods__Notion__SyncManifest -->|serialization: to_h| value_map_sort_by
  Woods__Notion__SyncManifest -->|serialization: to_a| current_keys
  Woods__Notion__SyncManifest -->|deserialization: parse| JSON
  Woods__Notion__SyncManifest_canonicalize[/"serialization"/]
  Woods__Notion__SyncManifest_canonicalize -->|serialization: to_h| value_map_sort_by
  Woods__Notion__SyncManifest_prune[/"serialization"/]
  Woods__Notion__SyncManifest_prune -->|serialization: to_a| current_keys
  Woods__Notion__SyncManifest_load[\"deserialization"\]
  Woods__Notion__SyncManifest_load -->|deserialization: parse| JSON
  Woods -->|construction: new| Hash
  Woods -->|construction: new| Set
  Woods__Obsidian(["new"])
  Woods__Obsidian -->|construction: new| Hash
  Woods__Obsidian -->|construction: new| Set
  Woods__Obsidian__NameMapper(["new"])
  Woods__Obsidian__NameMapper -->|construction: new| Hash
  Woods__Obsidian__NameMapper -->|construction: new| Set
  Woods__Obsidian__NameMapper_build(["new"])
  Woods__Obsidian__NameMapper_build -->|construction: new| Hash
  Woods__Obsidian__NameMapper_build -->|construction: new| Set
  Woods__Export__UnitFacts["Woods::Export::UnitFacts"]
  Woods -->|construction: new| Woods__Export__UnitFacts
  Woods -->|construction: new| Woods__Export__UnitFacts
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods__Obsidian -->|construction: new| Woods__Export__UnitFacts
  Woods__Obsidian -->|construction: new| Woods__Export__UnitFacts
  Woods__Obsidian -->|construction: new| Set
  Woods__Obsidian -->|construction: new| Set
  Woods__Obsidian -->|construction: new| Set
  Woods__Obsidian__NoteBuilder(["new"])
  Woods__Obsidian__NoteBuilder -->|construction: new| Woods__Export__UnitFacts
  Woods__Obsidian__NoteBuilder -->|construction: new| Woods__Export__UnitFacts
  Woods__Obsidian__NoteBuilder -->|construction: new| Set
  Woods__Obsidian__NoteBuilder -->|construction: new| Set
  Woods__Obsidian__NoteBuilder -->|construction: new| Set
  Woods__Obsidian__NoteBuilder_associations_section(["new"])
  Woods__Obsidian__NoteBuilder_associations_section -->|construction: new| Woods__Export__UnitFacts
  Woods__Obsidian__NoteBuilder_schema_section(["new"])
  Woods__Obsidian__NoteBuilder_schema_section -->|construction: new| Woods__Export__UnitFacts
  Woods__Obsidian__NoteBuilder_identifier_set(["new"])
  Woods__Obsidian__NoteBuilder_identifier_set -->|construction: new| Set
  Woods__Obsidian__NoteBuilder_plain_set(["new"])
  Woods__Obsidian__NoteBuilder_plain_set -->|construction: new| Set
  Woods__Obsidian__NoteBuilder_cycle_member_set(["new"])
  Woods__Obsidian__NoteBuilder_cycle_member_set -->|construction: new| Set
  Woods -->|construction: new| Pathname
  Woods -->|construction: new| Set
  NameMapper["NameMapper"]
  Woods -->|construction: new| NameMapper
  emitted["emitted"]
  Woods -->|serialization: to_h| emitted
  NoteBuilder["NoteBuilder"]
  Woods -->|construction: new| NoteBuilder
  Woods -->|serialization: to_h| emitted
  Woods -->|construction: new| Pathname
  hash_sort["hash.sort"]
  Woods -->|serialization: to_h| hash_sort
  Woods -->|construction: new| Woods__Console__CredentialScanner
  Woods -->|construction: new| Woods__MCP__IndexReader
  Woods__Obsidian -->|construction: new| Pathname
  Woods__Obsidian -->|construction: new| Set
  Woods__Obsidian -->|construction: new| NameMapper
  Woods__Obsidian -->|serialization: to_h| emitted
  Woods__Obsidian -->|construction: new| NoteBuilder
  Woods__Obsidian -->|serialization: to_h| emitted
  Woods__Obsidian -->|construction: new| Pathname
  Woods__Obsidian -->|serialization: to_h| hash_sort
  Woods__Obsidian -->|construction: new| Woods__Console__CredentialScanner
  Woods__Obsidian -->|construction: new| Woods__MCP__IndexReader
  Woods__Obsidian__VaultExporter(["new"])
  Woods__Obsidian__VaultExporter -->|construction: new| Pathname
  Woods__Obsidian__VaultExporter -->|construction: new| Set
  Woods__Obsidian__VaultExporter -->|construction: new| NameMapper
  Woods__Obsidian__VaultExporter -->|serialization: to_h| emitted
  Woods__Obsidian__VaultExporter -->|construction: new| NoteBuilder
  Woods__Obsidian__VaultExporter -->|serialization: to_h| emitted
  Woods__Obsidian__VaultExporter -->|construction: new| Pathname
  Woods__Obsidian__VaultExporter -->|serialization: to_h| hash_sort
  Woods__Obsidian__VaultExporter -->|construction: new| Woods__Console__CredentialScanner
  Woods__Obsidian__VaultExporter -->|construction: new| Woods__MCP__IndexReader
  Woods__Obsidian__VaultExporter_initialize(["new"])
  Woods__Obsidian__VaultExporter_initialize -->|construction: new| Pathname
  Woods__Obsidian__VaultExporter_export_all(["new"])
  Woods__Obsidian__VaultExporter_export_all -->|construction: new| Set
  Woods__Obsidian__VaultExporter_build_mapper(["new"])
  Woods__Obsidian__VaultExporter_build_mapper -->|construction: new| NameMapper
  Woods__Obsidian__VaultExporter_build_mapper -->|serialization: to_h| emitted
  Woods__Obsidian__VaultExporter_build_note_builder(["new"])
  Woods__Obsidian__VaultExporter_build_note_builder -->|construction: new| NoteBuilder
  Woods__Obsidian__VaultExporter_write_sidecar[/"serialization"/]
  Woods__Obsidian__VaultExporter_write_sidecar -->|serialization: to_h| emitted
  Woods__Obsidian__VaultExporter_canonical(["new"])
  Woods__Obsidian__VaultExporter_canonical -->|construction: new| Pathname
  Woods__Obsidian__VaultExporter_sort_hash[/"serialization"/]
  Woods__Obsidian__VaultExporter_sort_hash -->|serialization: to_h| hash_sort
  Woods__Obsidian__VaultExporter_scanner(["new"])
  Woods__Obsidian__VaultExporter_scanner -->|construction: new| Woods__Console__CredentialScanner
  Woods__Obsidian__VaultExporter_build_reader(["new"])
  Woods__Obsidian__VaultExporter_build_reader -->|construction: new| Woods__MCP__IndexReader
  Woods -->|deserialization: parse| JSON
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
  Woods__Operator__PipelineGuard_state_status[\"deserialization"\]
  Woods__Operator__PipelineGuard_state_status -->|deserialization: parse| JSON
  Woods__Operator__PipelineGuard_last_run[\"deserialization"\]
  Woods__Operator__PipelineGuard_last_run -->|deserialization: parse| Time
  Woods__Operator__PipelineGuard_parse_state[\"deserialization"\]
  Woods__Operator__PipelineGuard_parse_state -->|deserialization: parse| JSON
  Woods -->|construction: new| Woods__Generation
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| Time
  Woods__Operator -->|construction: new| Woods__Generation
  Woods__Operator -->|deserialization: parse| JSON
  Woods__Operator -->|deserialization: parse| Time
  Woods__Operator__StatusReporter(["new"])
  Woods__Operator__StatusReporter -->|construction: new| Woods__Generation
  Woods__Operator__StatusReporter -->|deserialization: parse| JSON
  Woods__Operator__StatusReporter -->|deserialization: parse| Time
  Woods__Operator__StatusReporter_read_manifest(["new"])
  Woods__Operator__StatusReporter_read_manifest -->|construction: new| Woods__Generation
  Woods__Operator__StatusReporter_read_manifest -->|deserialization: parse| JSON
  Woods__Operator__StatusReporter_compute_staleness[\"deserialization"\]
  Woods__Operator__StatusReporter_compute_staleness -->|deserialization: parse| Time
  Woods -->|construction: new| Struct
  exclude["exclude"]
  Woods -->|serialization: to_a| exclude
  dirs["dirs"]
  Woods -->|serialization: to_a| dirs
  k["k"]
  Woods -->|construction: new| k
  Rule["Rule"]
  Woods -->|construction: new| Rule
  Woods -->|construction: new| Rule
  Woods -->|construction: new| Set
  Woods__PathDispatcher(["new"])
  Woods__PathDispatcher -->|construction: new| Struct
  Woods__PathDispatcher -->|serialization: to_a| exclude
  Woods__PathDispatcher -->|serialization: to_a| dirs
  Woods__PathDispatcher -->|construction: new| k
  Woods__PathDispatcher -->|construction: new| Rule
  Woods__PathDispatcher -->|construction: new| Rule
  Woods__PathDispatcher -->|construction: new| Set
  Woods__PathDispatcher_whole_app_keys_for_all(["new"])
  Woods__PathDispatcher_whole_app_keys_for_all -->|construction: new| Set
  Woods -->|construction: new| Pathname
  Woods -->|construction: new| Pathname
  Woods -->|construction: new| Pathname
  Woods__PayloadStore(["new"])
  Woods__PayloadStore -->|construction: new| Pathname
  Woods__PayloadStore -->|construction: new| Pathname
  Woods__PayloadStore -->|construction: new| Pathname
  Woods__PayloadStore_initialize(["new"])
  Woods__PayloadStore_initialize -->|construction: new| Pathname
  Woods__PayloadStore_clone(["new"])
  Woods__PayloadStore_clone -->|construction: new| Pathname
  Woods__PayloadStore_clone -->|construction: new| Pathname
  Woods -->|construction: new| Pathname
  Woods -->|deserialization: parse| JSON
  Woods__Builder__PRESETS_keys_sort["Woods::Builder::PRESETS.keys.sort"]
  Woods -->|serialization: to_h| Woods__Builder__PRESETS_keys_sort
  predicate_names["predicate_names"]
  Woods -->|serialization: to_h| predicate_names
  Woods__Console__Server__EXECUTABLE_MODES_keys_sort["Woods::Console::Server::EXECUTABLE_MODES.keys.sort"]
  Woods -->|serialization: to_h| Woods__Console__Server__EXECUTABLE_MODES_keys_sort
  current_sort["current.sort"]
  Woods -->|serialization: to_h| current_sort
  current_public_documentation_paths["current_public_documentation_paths"]
  Woods -->|serialization: to_h| current_public_documentation_paths
  Woods -->|serialization: to_h| value_keys_sort_by
  Woods__ReleaseV2(["new"])
  Woods__ReleaseV2 -->|construction: new| Pathname
  Woods__ReleaseV2 -->|deserialization: parse| JSON
  Woods__ReleaseV2 -->|serialization: to_h| Woods__Builder__PRESETS_keys_sort
  Woods__ReleaseV2 -->|serialization: to_h| predicate_names
  Woods__ReleaseV2 -->|serialization: to_h| Woods__Console__Server__EXECUTABLE_MODES_keys_sort
  Woods__ReleaseV2 -->|serialization: to_h| current_sort
  Woods__ReleaseV2 -->|serialization: to_h| current_public_documentation_paths
  Woods__ReleaseV2 -->|serialization: to_h| value_keys_sort_by
  Woods__ReleaseV2__SurfaceInventory(["new"])
  Woods__ReleaseV2__SurfaceInventory -->|construction: new| Pathname
  Woods__ReleaseV2__SurfaceInventory -->|deserialization: parse| JSON
  Woods__ReleaseV2__SurfaceInventory -->|serialization: to_h| Woods__Builder__PRESETS_keys_sort
  Woods__ReleaseV2__SurfaceInventory -->|serialization: to_h| predicate_names
  Woods__ReleaseV2__SurfaceInventory -->|serialization: to_h| Woods__Console__Server__EXECUTABLE_MODES_keys_sort
  Woods__ReleaseV2__SurfaceInventory -->|serialization: to_h| current_sort
  Woods__ReleaseV2__SurfaceInventory -->|serialization: to_h| current_public_documentation_paths
  Woods__ReleaseV2__SurfaceInventory -->|serialization: to_h| value_keys_sort_by
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
  Woods -->|construction: new| Hash
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| Woods__Generation
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| Set
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| Set
  Woods__Resilience -->|construction: new| Struct
  Woods__Resilience -->|construction: new| ValidationReport
  Woods__Resilience -->|construction: new| ValidationReport
  Woods__Resilience -->|deserialization: parse| JSON
  Woods__Resilience -->|construction: new| Hash
  Woods__Resilience -->|deserialization: parse| JSON
  Woods__Resilience -->|deserialization: parse| JSON
  Woods__Resilience -->|construction: new| Woods__Generation
  Woods__Resilience -->|deserialization: parse| JSON
  Woods__Resilience -->|deserialization: parse| JSON
  Woods__Resilience -->|construction: new| Set
  Woods__Resilience -->|deserialization: parse| JSON
  Woods__Resilience -->|construction: new| Set
  Woods__Resilience__IndexValidator(["new"])
  Woods__Resilience__IndexValidator -->|construction: new| Struct
  Woods__Resilience__IndexValidator -->|construction: new| ValidationReport
  Woods__Resilience__IndexValidator -->|construction: new| ValidationReport
  Woods__Resilience__IndexValidator -->|deserialization: parse| JSON
  Woods__Resilience__IndexValidator -->|construction: new| Hash
  Woods__Resilience__IndexValidator -->|deserialization: parse| JSON
  Woods__Resilience__IndexValidator -->|deserialization: parse| JSON
  Woods__Resilience__IndexValidator -->|construction: new| Woods__Generation
  Woods__Resilience__IndexValidator -->|deserialization: parse| JSON
  Woods__Resilience__IndexValidator -->|deserialization: parse| JSON
  Woods__Resilience__IndexValidator -->|construction: new| Set
  Woods__Resilience__IndexValidator -->|deserialization: parse| JSON
  Woods__Resilience__IndexValidator -->|construction: new| Set
  Woods__Resilience__IndexValidator_validate(["new"])
  Woods__Resilience__IndexValidator_validate -->|construction: new| ValidationReport
  Woods__Resilience__IndexValidator_validate -->|construction: new| ValidationReport
  Woods__Resilience__IndexValidator_validate_against_manifest(["parse"])
  Woods__Resilience__IndexValidator_validate_against_manifest -->|deserialization: parse| JSON
  Woods__Resilience__IndexValidator_validate_against_manifest -->|construction: new| Hash
  Woods__Resilience__IndexValidator_validate_unit_file[\"deserialization"\]
  Woods__Resilience__IndexValidator_validate_unit_file -->|deserialization: parse| JSON
  Woods__Resilience__IndexValidator_validate_dependency_graph[\"deserialization"\]
  Woods__Resilience__IndexValidator_validate_dependency_graph -->|deserialization: parse| JSON
  Woods__Resilience__IndexValidator_payload_dir(["new"])
  Woods__Resilience__IndexValidator_payload_dir -->|construction: new| Woods__Generation
  Woods__Resilience__IndexValidator_parse_artifact[\"deserialization"\]
  Woods__Resilience__IndexValidator_parse_artifact -->|deserialization: parse| JSON
  Woods__Resilience__IndexValidator_validate_type_directory(["parse"])
  Woods__Resilience__IndexValidator_validate_type_directory -->|deserialization: parse| JSON
  Woods__Resilience__IndexValidator_validate_type_directory -->|construction: new| Set
  Woods__Resilience__IndexValidator_validate_content_hash[\"deserialization"\]
  Woods__Resilience__IndexValidator_validate_content_hash -->|deserialization: parse| JSON
  Woods__Resilience__IndexValidator_check_stale_files(["new"])
  Woods__Resilience__IndexValidator_check_stale_files -->|construction: new| Set
  Woods__MCP__DimensionMismatch["Woods::MCP::DimensionMismatch"]
  Woods -->|construction: new| Woods__MCP__DimensionMismatch
  Woods__MCP__ConfigMismatch["Woods::MCP::ConfigMismatch"]
  Woods -->|construction: new| Woods__MCP__ConfigMismatch
  Woods__MCP__UnsupportedArtifact["Woods::MCP::UnsupportedArtifact"]
  Woods -->|construction: new| Woods__MCP__UnsupportedArtifact
  Woods -->|deserialization: parse| Time
  Woods__ResolvedConfig(["new"])
  Woods__ResolvedConfig -->|construction: new| Woods__MCP__DimensionMismatch
  Woods__ResolvedConfig -->|construction: new| Woods__MCP__ConfigMismatch
  Woods__ResolvedConfig -->|construction: new| Woods__MCP__UnsupportedArtifact
  Woods__ResolvedConfig -->|deserialization: parse| Time
  Woods__ResolvedConfig_from_hash(["new"])
  Woods__ResolvedConfig_from_configuration(["new"])
  Woods__ResolvedConfig_assert_dimensions_match_(["new"])
  Woods__ResolvedConfig_assert_dimensions_match_ -->|construction: new| Woods__MCP__DimensionMismatch
  Woods__ResolvedConfig_assert_provider_matches_(["new"])
  Woods__ResolvedConfig_assert_provider_matches_ -->|construction: new| Woods__MCP__ConfigMismatch
  SearchExecutor__Candidate["SearchExecutor::Candidate"]
  Woods -->|construction: new| SearchExecutor__Candidate
  AssembledContext["AssembledContext"]
  Woods -->|construction: new| AssembledContext
  Woods -->|construction: new| Struct
  Woods__Retrieval(["new"])
  Woods__Retrieval -->|construction: new| SearchExecutor__Candidate
  Woods__Retrieval -->|construction: new| AssembledContext
  Woods__Retrieval -->|construction: new| Struct
  Woods__Retrieval__ContextAssembler(["new"])
  Woods__Retrieval__ContextAssembler -->|construction: new| SearchExecutor__Candidate
  Woods__Retrieval__ContextAssembler -->|construction: new| AssembledContext
  Woods__Retrieval__ContextAssembler_rewrite_identifier(["new"])
  Woods__Retrieval__ContextAssembler_rewrite_identifier -->|construction: new| SearchExecutor__Candidate
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
  candidates["candidates"]
  Woods -->|serialization: to_h| candidates
  ranked_each_with_index["ranked.each_with_index"]
  Woods -->|serialization: to_h| ranked_each_with_index
  Woods -->|construction: new| Hash
  Woods -->|construction: new| Hash
  Woods -->|construction: new| SearchExecutor__Candidate
  Woods__Retrieval -->|construction: new| Hash
  Woods__Retrieval -->|serialization: to_h| candidates
  Woods__Retrieval -->|serialization: to_h| ranked_each_with_index
  Woods__Retrieval -->|construction: new| Hash
  Woods__Retrieval -->|construction: new| Hash
  Woods__Retrieval -->|construction: new| SearchExecutor__Candidate
  Woods__Retrieval__Ranker(["new"])
  Woods__Retrieval__Ranker -->|construction: new| Hash
  Woods__Retrieval__Ranker -->|serialization: to_h| candidates
  Woods__Retrieval__Ranker -->|serialization: to_h| ranked_each_with_index
  Woods__Retrieval__Ranker -->|construction: new| Hash
  Woods__Retrieval__Ranker -->|construction: new| Hash
  Woods__Retrieval__Ranker -->|construction: new| SearchExecutor__Candidate
  Woods__Retrieval__Ranker_compute_rrf_scores(["new"])
  Woods__Retrieval__Ranker_compute_rrf_scores -->|construction: new| Hash
  Woods__Retrieval__Ranker_score_candidates[/"serialization"/]
  Woods__Retrieval__Ranker_score_candidates -->|serialization: to_h| candidates
  Woods__Retrieval__Ranker_compute_pagerank_importance_map[/"serialization"/]
  Woods__Retrieval__Ranker_compute_pagerank_importance_map -->|serialization: to_h| ranked_each_with_index
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
  Woods -->|construction: new| Candidate
  Woods -->|construction: new| Candidate
  Woods -->|construction: new| Candidate
  Woods -->|construction: new| Candidate
  Woods -->|construction: new| Candidate
  Woods__Retrieval -->|construction: new| Struct
  Woods__Retrieval -->|construction: new| Struct
  Woods__Retrieval -->|construction: new| ExecutionResult
  Woods__Retrieval -->|construction: new| Candidate
  Woods__Retrieval -->|construction: new| Candidate
  Woods__Retrieval -->|construction: new| Candidate
  Woods__Retrieval -->|construction: new| Candidate
  Woods__Retrieval -->|construction: new| Candidate
  Woods__Retrieval -->|construction: new| Candidate
  Woods__Retrieval -->|construction: new| Candidate
  Woods__Retrieval__SearchExecutor(["new"])
  Woods__Retrieval__SearchExecutor -->|construction: new| Struct
  Woods__Retrieval__SearchExecutor -->|construction: new| Struct
  Woods__Retrieval__SearchExecutor -->|construction: new| ExecutionResult
  Woods__Retrieval__SearchExecutor -->|construction: new| Candidate
  Woods__Retrieval__SearchExecutor -->|construction: new| Candidate
  Woods__Retrieval__SearchExecutor -->|construction: new| Candidate
  Woods__Retrieval__SearchExecutor -->|construction: new| Candidate
  Woods__Retrieval__SearchExecutor -->|construction: new| Candidate
  Woods__Retrieval__SearchExecutor -->|construction: new| Candidate
  Woods__Retrieval__SearchExecutor -->|construction: new| Candidate
  Woods__Retrieval__SearchExecutor_execute(["new"])
  Woods__Retrieval__SearchExecutor_execute -->|construction: new| ExecutionResult
  Woods__Retrieval__SearchExecutor_execute_vector(["new"])
  Woods__Retrieval__SearchExecutor_execute_vector -->|construction: new| Candidate
  Woods__Retrieval__SearchExecutor_rank_keyword_results(["new"])
  Woods__Retrieval__SearchExecutor_rank_keyword_results -->|construction: new| Candidate
  Woods__Retrieval__SearchExecutor_execute_graph(["new"])
  Woods__Retrieval__SearchExecutor_execute_graph -->|construction: new| Candidate
  Woods__Retrieval__SearchExecutor_execute_graph -->|construction: new| Candidate
  Woods__Retrieval__SearchExecutor_execute_graph -->|construction: new| Candidate
  Woods__Retrieval__SearchExecutor_execute_hybrid(["new"])
  Woods__Retrieval__SearchExecutor_execute_hybrid -->|construction: new| Candidate
  Woods__Retrieval__SearchExecutor_lookup_keyword_variants(["new"])
  Woods__Retrieval__SearchExecutor_lookup_keyword_variants -->|construction: new| Candidate
  Woods -->|construction: new| Struct
  Woods -->|construction: new| Struct
  Woods -->|construction: new| Struct
  Retrieval__QueryClassifier["Retrieval::QueryClassifier"]
  Woods -->|construction: new| Retrieval__QueryClassifier
  Pipeline["Pipeline"]
  Woods -->|construction: new| Pipeline
  Retrieval__SearchExecutor["Retrieval::SearchExecutor"]
  Woods -->|construction: new| Retrieval__SearchExecutor
  Retrieval__Ranker["Retrieval::Ranker"]
  Woods -->|construction: new| Retrieval__Ranker
  Retrieval__ContextAssembler["Retrieval::ContextAssembler"]
  Woods -->|construction: new| Retrieval__ContextAssembler
  Woods -->|construction: new| Embedding__TokenCounter
  Woods -->|construction: new| Set
  RetrievalResult["RetrievalResult"]
  Woods -->|construction: new| RetrievalResult
  type_list["type_list"]
  Woods -->|serialization: to_a| type_list
  RetrievalTrace["RetrievalTrace"]
  Woods -->|construction: new| RetrievalTrace
  Woods -->|serialization: to_h| type_list
  Woods__Retriever(["new"])
  Woods__Retriever -->|construction: new| Struct
  Woods__Retriever -->|construction: new| Struct
  Woods__Retriever -->|construction: new| Struct
  Woods__Retriever -->|construction: new| Retrieval__QueryClassifier
  Woods__Retriever -->|construction: new| Pipeline
  Woods__Retriever -->|construction: new| Retrieval__SearchExecutor
  Woods__Retriever -->|construction: new| Retrieval__Ranker
  Woods__Retriever -->|construction: new| Retrieval__ContextAssembler
  Woods__Retriever -->|construction: new| Embedding__TokenCounter
  Woods__Retriever -->|construction: new| Set
  Woods__Retriever -->|construction: new| RetrievalResult
  Woods__Retriever -->|serialization: to_a| type_list
  Woods__Retriever -->|construction: new| RetrievalTrace
  Woods__Retriever -->|serialization: to_h| type_list
  Woods__Retriever_initialize(["new"])
  Woods__Retriever_initialize -->|construction: new| Retrieval__QueryClassifier
  Woods__Retriever_build_pipeline(["new"])
  Woods__Retriever_build_pipeline -->|construction: new| Pipeline
  Woods__Retriever_build_pipeline -->|construction: new| Retrieval__SearchExecutor
  Woods__Retriever_build_pipeline -->|construction: new| Retrieval__Ranker
  Woods__Retriever_build_pipeline -->|construction: new| Retrieval__ContextAssembler
  Woods__Retriever_infer_token_counter(["new"])
  Woods__Retriever_infer_token_counter -->|construction: new| Embedding__TokenCounter
  Woods__Retriever_filter_by_type(["new"])
  Woods__Retriever_filter_by_type -->|construction: new| Set
  Woods__Retriever_build_result(["new"])
  Woods__Retriever_build_result -->|construction: new| RetrievalResult
  Woods__Retriever_within_type_fallback[/"serialization"/]
  Woods__Retriever_within_type_fallback -->|serialization: to_a| type_list
  Woods__Retriever_build_trace(["new"])
  Woods__Retriever_build_trace -->|construction: new| RetrievalTrace
  Woods__Retriever_build_type_rank_context[/"serialization"/]
  Woods__Retriever_build_type_rank_context -->|serialization: to_h| type_list
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
  ___________CONSTRUCTION_METHODS_map____m___m___construction______________SERIALIZATION_METHODS_map____m___m___serialization______________DESERIALIZATION_METHODS_map____m___m___deserialization___________["[
        *CONSTRUCTION_METHODS.map { |m| [m, :construction] },
        *SERIALIZATION_METHODS.map { |m| [m, :serialization] },
        *DESERIALIZATION_METHODS.map { |m| [m, :deserialization] }
      ]"]
  Woods -->|serialization: to_h| ___________CONSTRUCTION_METHODS_map____m___m___construction______________SERIALIZATION_METHODS_map____m___m___serialization______________DESERIALIZATION_METHODS_map____m___m___deserialization___________
  Woods -->|construction: new| Ast__Parser
  Ast__CallSiteExtractor["Ast::CallSiteExtractor"]
  Woods -->|construction: new| Ast__CallSiteExtractor
  Woods -->|deserialization: parse| _parser
  Woods__RubyAnalyzer -->|serialization: to_h| ___________CONSTRUCTION_METHODS_map____m___m___construction______________SERIALIZATION_METHODS_map____m___m___serialization______________DESERIALIZATION_METHODS_map____m___m___deserialization___________
  Woods__RubyAnalyzer -->|construction: new| Ast__Parser
  Woods__RubyAnalyzer -->|construction: new| Ast__CallSiteExtractor
  Woods__RubyAnalyzer -->|deserialization: parse| _parser
  Woods__RubyAnalyzer__DataFlowAnalyzer(["to_h"])
  Woods__RubyAnalyzer__DataFlowAnalyzer -->|serialization: to_h| ___________CONSTRUCTION_METHODS_map____m___m___construction______________SERIALIZATION_METHODS_map____m___m___serialization______________DESERIALIZATION_METHODS_map____m___m___deserialization___________
  Woods__RubyAnalyzer__DataFlowAnalyzer -->|construction: new| Ast__Parser
  Woods__RubyAnalyzer__DataFlowAnalyzer -->|construction: new| Ast__CallSiteExtractor
  Woods__RubyAnalyzer__DataFlowAnalyzer -->|deserialization: parse| _parser
  Woods__RubyAnalyzer__DataFlowAnalyzer_initialize(["new"])
  Woods__RubyAnalyzer__DataFlowAnalyzer_initialize -->|construction: new| Ast__Parser
  Woods__RubyAnalyzer__DataFlowAnalyzer_initialize -->|construction: new| Ast__CallSiteExtractor
  Woods__RubyAnalyzer__DataFlowAnalyzer_detect_transformations[\"deserialization"\]
  Woods__RubyAnalyzer__DataFlowAnalyzer_detect_transformations -->|deserialization: parse| _parser
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods__RubyAnalyzer -->|construction: new| Set
  Woods__RubyAnalyzer -->|construction: new| Set
  Woods__RubyAnalyzer -->|construction: new| Set
  Woods__RubyAnalyzer -->|construction: new| Set
  Woods__RubyAnalyzer__MermaidRenderer(["new"])
  Woods__RubyAnalyzer__MermaidRenderer -->|construction: new| Set
  Woods__RubyAnalyzer__MermaidRenderer -->|construction: new| Set
  Woods__RubyAnalyzer__MermaidRenderer -->|construction: new| Set
  Woods__RubyAnalyzer__MermaidRenderer -->|construction: new| Set
  Woods__RubyAnalyzer__MermaidRenderer_render_call_graph(["new"])
  Woods__RubyAnalyzer__MermaidRenderer_render_call_graph -->|construction: new| Set
  Woods__RubyAnalyzer__MermaidRenderer_render_call_graph -->|construction: new| Set
  Woods__RubyAnalyzer__MermaidRenderer_render_dependency_map(["new"])
  Woods__RubyAnalyzer__MermaidRenderer_render_dependency_map -->|construction: new| Set
  Woods__RubyAnalyzer__MermaidRenderer_render_dataflow(["new"])
  Woods__RubyAnalyzer__MermaidRenderer_render_dataflow -->|construction: new| Set
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
  Woods -->|construction: new| Mutex
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| Tempfile
  Woods__SessionTracer(["new"])
  Woods__SessionTracer -->|construction: new| Mutex
  Woods__SessionTracer -->|deserialization: parse| JSON
  Woods__SessionTracer -->|construction: new| Tempfile
  Woods__SessionTracer__FileStore(["new"])
  Woods__SessionTracer__FileStore -->|construction: new| Mutex
  Woods__SessionTracer__FileStore -->|deserialization: parse| JSON
  Woods__SessionTracer__FileStore -->|construction: new| Tempfile
  Woods__SessionTracer__FileStore_initialize(["new"])
  Woods__SessionTracer__FileStore_initialize -->|construction: new| Mutex
  Woods__SessionTracer__FileStore_read[\"deserialization"\]
  Woods__SessionTracer__FileStore_read -->|deserialization: parse| JSON
  Woods__SessionTracer__FileStore_atomic_replace(["new"])
  Woods__SessionTracer__FileStore_atomic_replace -->|construction: new| Tempfile
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
  Woods -->|construction: new| SessionFlowDocument
  Woods__SessionTracer -->|construction: new| Set
  Woods__SessionTracer -->|construction: new| SessionFlowDocument
  Woods__SessionTracer -->|construction: new| SessionFlowDocument
  Woods__SessionTracer -->|construction: new| SessionFlowDocument
  Woods__SessionTracer__SessionFlowAssembler -->|construction: new| Set
  Woods__SessionTracer__SessionFlowAssembler -->|construction: new| SessionFlowDocument
  Woods__SessionTracer__SessionFlowAssembler -->|construction: new| SessionFlowDocument
  Woods__SessionTracer__SessionFlowAssembler -->|construction: new| SessionFlowDocument
  Woods__SessionTracer__SessionFlowAssembler_assemble(["new"])
  Woods__SessionTracer__SessionFlowAssembler_assemble -->|construction: new| Set
  Woods__SessionTracer__SessionFlowAssembler_budgeted_document(["new"])
  Woods__SessionTracer__SessionFlowAssembler_budgeted_document -->|construction: new| SessionFlowDocument
  Woods__SessionTracer__SessionFlowAssembler_rendered_tokens(["new"])
  Woods__SessionTracer__SessionFlowAssembler_rendered_tokens -->|construction: new| SessionFlowDocument
  Woods__SessionTracer__SessionFlowAssembler_empty_document(["new"])
  Woods__SessionTracer__SessionFlowAssembler_empty_document -->|construction: new| SessionFlowDocument
  Woods__SessionTracer__SessionFlowDocument(["new"])
  Woods__SessionTracer__SessionFlowDocument_from_h(["new"])
  Woods -->|construction: new| Object
  ActiveSupport__Cache__Entry["ActiveSupport::Cache::Entry"]
  Woods -->|construction: new| ActiveSupport__Cache__Entry
  Woods__SessionTracer -->|construction: new| Object
  Woods__SessionTracer -->|construction: new| ActiveSupport__Cache__Entry
  Woods__SessionTracer__SolidCacheCoordination(["new"])
  Woods__SessionTracer__SolidCacheCoordination -->|construction: new| Object
  Woods__SessionTracer__SolidCacheCoordination -->|construction: new| ActiveSupport__Cache__Entry
  Woods__SessionTracer__SolidCacheCoordination_cache_entry(["new"])
  Woods__SessionTracer__SolidCacheCoordination_cache_entry -->|construction: new| ActiveSupport__Cache__Entry
  Woods -->|construction: new| Struct
  SolidCacheCoordination["SolidCacheCoordination"]
  Woods -->|construction: new| SolidCacheCoordination
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  DirectorySlot["DirectorySlot"]
  Woods -->|construction: new| DirectorySlot
  Woods -->|deserialization: parse| JSON
  Woods__SessionTracer -->|construction: new| Struct
  Woods__SessionTracer -->|construction: new| SolidCacheCoordination
  Woods__SessionTracer -->|deserialization: parse| JSON
  Woods__SessionTracer -->|deserialization: parse| JSON
  Woods__SessionTracer -->|deserialization: parse| JSON
  Woods__SessionTracer -->|deserialization: parse| JSON
  Woods__SessionTracer -->|construction: new| DirectorySlot
  Woods__SessionTracer -->|deserialization: parse| JSON
  Woods__SessionTracer__SolidCacheStore(["new"])
  Woods__SessionTracer__SolidCacheStore -->|construction: new| Struct
  Woods__SessionTracer__SolidCacheStore -->|construction: new| SolidCacheCoordination
  Woods__SessionTracer__SolidCacheStore -->|deserialization: parse| JSON
  Woods__SessionTracer__SolidCacheStore -->|deserialization: parse| JSON
  Woods__SessionTracer__SolidCacheStore -->|deserialization: parse| JSON
  Woods__SessionTracer__SolidCacheStore -->|deserialization: parse| JSON
  Woods__SessionTracer__SolidCacheStore -->|construction: new| DirectorySlot
  Woods__SessionTracer__SolidCacheStore -->|deserialization: parse| JSON
  Woods__SessionTracer__SolidCacheStore_initialize(["new"])
  Woods__SessionTracer__SolidCacheStore_initialize -->|construction: new| SolidCacheCoordination
  Woods__SessionTracer__SolidCacheStore_record[\"deserialization"\]
  Woods__SessionTracer__SolidCacheStore_record -->|deserialization: parse| JSON
  Woods__SessionTracer__SolidCacheStore_parse_record[\"deserialization"\]
  Woods__SessionTracer__SolidCacheStore_parse_record -->|deserialization: parse| JSON
  Woods__SessionTracer__SolidCacheStore_payload_sequence[\"deserialization"\]
  Woods__SessionTracer__SolidCacheStore_payload_sequence -->|deserialization: parse| JSON
  Woods__SessionTracer__SolidCacheStore_payload_token[\"deserialization"\]
  Woods__SessionTracer__SolidCacheStore_payload_token -->|deserialization: parse| JSON
  Woods__SessionTracer__SolidCacheStore_directory_slots(["new"])
  Woods__SessionTracer__SolidCacheStore_directory_slots -->|construction: new| DirectorySlot
  Woods__SessionTracer__SolidCacheStore_parse_membership[\"deserialization"\]
  Woods__SessionTracer__SolidCacheStore_parse_membership -->|deserialization: parse| JSON
  Woods -->|construction: new| DependencyGraph
  Woods__Storage(["new"])
  Woods__Storage -->|construction: new| DependencyGraph
  Woods__Storage__GraphStore(["new"])
  Woods__Storage__GraphStore -->|construction: new| DependencyGraph
  Woods__Storage__GraphStore__Memory -->|construction: new| DependencyGraph
  Woods__Storage__GraphStore__Memory_initialize(["new"])
  Woods__Storage__GraphStore__Memory_initialize -->|construction: new| DependencyGraph
  Woods -->|construction: new| SQLite3__Database
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| Array
  rows["rows"]
  Woods -->|serialization: to_h| rows
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| Array
  Woods -->|deserialization: parse| JSON
  Woods__Storage -->|construction: new| SQLite3__Database
  Woods__Storage -->|deserialization: parse| JSON
  Woods__Storage -->|construction: new| Array
  Woods__Storage -->|serialization: to_h| rows
  Woods__Storage -->|deserialization: parse| JSON
  Woods__Storage -->|construction: new| Array
  Woods__Storage -->|deserialization: parse| JSON
  Woods__Storage__MetadataStore(["new"])
  Woods__Storage__MetadataStore -->|construction: new| SQLite3__Database
  Woods__Storage__MetadataStore -->|deserialization: parse| JSON
  Woods__Storage__MetadataStore -->|construction: new| Array
  Woods__Storage__MetadataStore -->|serialization: to_h| rows
  Woods__Storage__MetadataStore -->|deserialization: parse| JSON
  Woods__Storage__MetadataStore -->|construction: new| Array
  Woods__Storage__MetadataStore -->|deserialization: parse| JSON
  Woods__Storage__MetadataStore__SQLite(["new"])
  Woods__Storage__MetadataStore__SQLite -->|construction: new| SQLite3__Database
  Woods__Storage__MetadataStore__SQLite -->|deserialization: parse| JSON
  Woods__Storage__MetadataStore__SQLite -->|construction: new| Array
  Woods__Storage__MetadataStore__SQLite -->|serialization: to_h| rows
  Woods__Storage__MetadataStore__SQLite -->|deserialization: parse| JSON
  Woods__Storage__MetadataStore__SQLite -->|construction: new| Array
  Woods__Storage__MetadataStore__SQLite -->|deserialization: parse| JSON
  Woods__Storage__MetadataStore__SQLite_initialize(["new"])
  Woods__Storage__MetadataStore__SQLite_initialize -->|construction: new| SQLite3__Database
  Woods__Storage__MetadataStore__SQLite_find[\"deserialization"\]
  Woods__Storage__MetadataStore__SQLite_find -->|deserialization: parse| JSON
  Woods__Storage__MetadataStore__SQLite_find_batch(["new"])
  Woods__Storage__MetadataStore__SQLite_find_batch -->|construction: new| Array
  Woods__Storage__MetadataStore__SQLite_find_batch -->|serialization: to_h| rows
  Woods__Storage__MetadataStore__SQLite_find_batch -->|deserialization: parse| JSON
  Woods__Storage__MetadataStore__SQLite_search(["new"])
  Woods__Storage__MetadataStore__SQLite_search -->|construction: new| Array
  Woods__Storage__MetadataStore__SQLite_parse_row[\"deserialization"\]
  Woods__Storage__MetadataStore__SQLite_parse_row -->|deserialization: parse| JSON
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
  IPAddr["IPAddr"]
  Woods -->|construction: new| IPAddr
  Woods -->|construction: new| IPAddr
  Woods -->|construction: new| IPAddr
  Woods -->|construction: new| SearchResult
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| RequestError
  Woods -->|construction: new| RequestError
  Woods -->|construction: new| RequestError
  Woods -->|construction: new| Net__HTTP
  request_class["request_class"]
  Woods -->|construction: new| request_class
  Woods -->|serialization: to_json| body
  Woods__Storage -->|construction: new| IPAddr
  Woods__Storage -->|construction: new| IPAddr
  Woods__Storage -->|construction: new| IPAddr
  Woods__Storage -->|construction: new| SearchResult
  Woods__Storage -->|deserialization: parse| JSON
  Woods__Storage -->|construction: new| RequestError
  Woods__Storage -->|construction: new| RequestError
  Woods__Storage -->|construction: new| RequestError
  Woods__Storage -->|construction: new| Net__HTTP
  Woods__Storage -->|construction: new| request_class
  Woods__Storage -->|serialization: to_json| body
  Woods__Storage__VectorStore -->|construction: new| IPAddr
  Woods__Storage__VectorStore -->|construction: new| IPAddr
  Woods__Storage__VectorStore -->|construction: new| IPAddr
  Woods__Storage__VectorStore -->|construction: new| SearchResult
  Woods__Storage__VectorStore -->|deserialization: parse| JSON
  Woods__Storage__VectorStore -->|construction: new| RequestError
  Woods__Storage__VectorStore -->|construction: new| RequestError
  Woods__Storage__VectorStore -->|construction: new| RequestError
  Woods__Storage__VectorStore -->|construction: new| Net__HTTP
  Woods__Storage__VectorStore -->|construction: new| request_class
  Woods__Storage__VectorStore -->|serialization: to_json| body
  Woods__Storage__VectorStore__Qdrant(["new"])
  Woods__Storage__VectorStore__Qdrant -->|construction: new| IPAddr
  Woods__Storage__VectorStore__Qdrant -->|construction: new| IPAddr
  Woods__Storage__VectorStore__Qdrant -->|construction: new| IPAddr
  Woods__Storage__VectorStore__Qdrant -->|construction: new| SearchResult
  Woods__Storage__VectorStore__Qdrant -->|deserialization: parse| JSON
  Woods__Storage__VectorStore__Qdrant -->|construction: new| RequestError
  Woods__Storage__VectorStore__Qdrant -->|construction: new| RequestError
  Woods__Storage__VectorStore__Qdrant -->|construction: new| RequestError
  Woods__Storage__VectorStore__Qdrant -->|construction: new| Net__HTTP
  Woods__Storage__VectorStore__Qdrant -->|construction: new| request_class
  Woods__Storage__VectorStore__Qdrant -->|serialization: to_json| body
  Woods__Storage__VectorStore__Qdrant_private_host_(["new"])
  Woods__Storage__VectorStore__Qdrant_private_host_ -->|construction: new| IPAddr
  Woods__Storage__VectorStore__Qdrant_unmap_ipv4(["new"])
  Woods__Storage__VectorStore__Qdrant_unmap_ipv4 -->|construction: new| IPAddr
  Woods__Storage__VectorStore__Qdrant_search(["new"])
  Woods__Storage__VectorStore__Qdrant_search -->|construction: new| SearchResult
  Woods__Storage__VectorStore__Qdrant_parse_response(["parse"])
  Woods__Storage__VectorStore__Qdrant_parse_response -->|deserialization: parse| JSON
  Woods__Storage__VectorStore__Qdrant_parse_response -->|construction: new| RequestError
  Woods__Storage__VectorStore__Qdrant_response_error(["new"])
  Woods__Storage__VectorStore__Qdrant_response_error -->|construction: new| RequestError
  Woods__Storage__VectorStore__Qdrant_transport_error(["new"])
  Woods__Storage__VectorStore__Qdrant_transport_error -->|construction: new| RequestError
  Woods__Storage__VectorStore__Qdrant_http_client(["new"])
  Woods__Storage__VectorStore__Qdrant_http_client -->|construction: new| Net__HTTP
  Woods__Storage__VectorStore__Qdrant_build_request(["new"])
  Woods__Storage__VectorStore__Qdrant_build_request -->|construction: new| request_class
  Woods__Storage__VectorStore__Qdrant_build_request -->|serialization: to_json| body
  Woods -->|construction: new| Pathname
  MetadataStore__InMemory["MetadataStore::InMemory"]
  Woods -->|construction: new| MetadataStore__InMemory
  MessagePack__Unpacker["MessagePack::Unpacker"]
  Woods -->|construction: new| MessagePack__Unpacker
  Woods -->|construction: new| MetadataStore__InMemory
  Woods__MCP__MissingArtifact["Woods::MCP::MissingArtifact"]
  Woods -->|construction: new| Woods__MCP__MissingArtifact
  Woods -->|construction: new| Pathname
  Woods -->|construction: new| Tempfile
  MessagePack__Packer["MessagePack::Packer"]
  Woods -->|construction: new| MessagePack__Packer
  Woods__Storage -->|construction: new| Pathname
  Woods__Storage -->|construction: new| MetadataStore__InMemory
  Woods__Storage -->|construction: new| MessagePack__Unpacker
  Woods__Storage -->|construction: new| MetadataStore__InMemory
  Woods__Storage -->|construction: new| Woods__MCP__MissingArtifact
  Woods__Storage -->|construction: new| Pathname
  Woods__Storage -->|construction: new| Tempfile
  Woods__Storage -->|construction: new| MessagePack__Packer
  Woods__Storage__Snapshotter(["new"])
  Woods__Storage__Snapshotter -->|construction: new| Pathname
  Woods__Storage__Snapshotter -->|construction: new| MetadataStore__InMemory
  Woods__Storage__Snapshotter -->|construction: new| MessagePack__Unpacker
  Woods__Storage__Snapshotter -->|construction: new| MetadataStore__InMemory
  Woods__Storage__Snapshotter -->|construction: new| Woods__MCP__MissingArtifact
  Woods__Storage__Snapshotter -->|construction: new| Pathname
  Woods__Storage__Snapshotter -->|construction: new| Tempfile
  Woods__Storage__Snapshotter -->|construction: new| MessagePack__Packer
  Woods__Storage__Snapshotter__Metadata(["new"])
  Woods__Storage__Snapshotter__Metadata -->|construction: new| Pathname
  Woods__Storage__Snapshotter__Metadata -->|construction: new| MetadataStore__InMemory
  Woods__Storage__Snapshotter__Metadata -->|construction: new| MessagePack__Unpacker
  Woods__Storage__Snapshotter__Metadata -->|construction: new| MetadataStore__InMemory
  Woods__Storage__Snapshotter__Metadata -->|construction: new| Woods__MCP__MissingArtifact
  Woods__Storage__Snapshotter__Metadata -->|construction: new| Pathname
  Woods__Storage__Snapshotter__Metadata -->|construction: new| Tempfile
  Woods__Storage__Snapshotter__Metadata -->|construction: new| MessagePack__Packer
  Woods__Storage__Snapshotter__Metadata_load_dump_dir(["new"])
  Woods__Storage__Snapshotter__Metadata_load_dump_dir -->|construction: new| Pathname
  Woods__Storage__Snapshotter__Metadata_load_dump_dir -->|construction: new| MetadataStore__InMemory
  Woods__Storage__Snapshotter__Metadata_load_dump_dir -->|construction: new| MessagePack__Unpacker
  Woods__Storage__Snapshotter__Metadata_missing_dump_store(["new"])
  Woods__Storage__Snapshotter__Metadata_missing_dump_store -->|construction: new| MetadataStore__InMemory
  Woods__Storage__Snapshotter__Metadata_missing_dump_store -->|construction: new| Woods__MCP__MissingArtifact
  Woods__Storage__Snapshotter__Metadata_dump(["new"])
  Woods__Storage__Snapshotter__Metadata_dump -->|construction: new| Pathname
  Woods -->|construction: new| Pathname
  VectorStore__InMemory["VectorStore::InMemory"]
  Woods -->|construction: new| VectorStore__InMemory
  Woods -->|construction: new| Woods__MCP__MissingArtifact
  store_each_entry["store.each_entry"]
  Woods -->|serialization: to_a| store_each_entry
  Woods -->|construction: new| Pathname
  Woods -->|construction: new| Woods__MCP__UnsupportedArtifact
  Woods -->|construction: new| Woods__MCP__UnsupportedArtifact
  Woods -->|construction: new| VectorStore__InMemory
  Woods -->|construction: new| Woods__MCP__UnsupportedArtifact
  Woods -->|construction: new| Woods__MCP__UnsupportedArtifact
  Woods -->|construction: new| Woods__MCP__DimensionMismatch
  Woods -->|construction: new| String
  Woods -->|construction: new| String
  Woods -->|construction: new| Tempfile
  Woods__Storage -->|construction: new| Pathname
  Woods__Storage -->|construction: new| VectorStore__InMemory
  Woods__Storage -->|construction: new| Woods__MCP__MissingArtifact
  Woods__Storage -->|serialization: to_a| store_each_entry
  Woods__Storage -->|construction: new| Pathname
  Woods__Storage -->|construction: new| Woods__MCP__UnsupportedArtifact
  Woods__Storage -->|construction: new| Woods__MCP__UnsupportedArtifact
  Woods__Storage -->|construction: new| VectorStore__InMemory
  Woods__Storage -->|construction: new| Woods__MCP__UnsupportedArtifact
  Woods__Storage -->|construction: new| Woods__MCP__UnsupportedArtifact
  Woods__Storage -->|construction: new| Woods__MCP__DimensionMismatch
  Woods__Storage -->|construction: new| String
  Woods__Storage -->|construction: new| String
  Woods__Storage -->|construction: new| Tempfile
  Woods__Storage__Snapshotter -->|construction: new| Pathname
  Woods__Storage__Snapshotter -->|construction: new| VectorStore__InMemory
  Woods__Storage__Snapshotter -->|construction: new| Woods__MCP__MissingArtifact
  Woods__Storage__Snapshotter -->|serialization: to_a| store_each_entry
  Woods__Storage__Snapshotter -->|construction: new| Pathname
  Woods__Storage__Snapshotter -->|construction: new| Woods__MCP__UnsupportedArtifact
  Woods__Storage__Snapshotter -->|construction: new| Woods__MCP__UnsupportedArtifact
  Woods__Storage__Snapshotter -->|construction: new| VectorStore__InMemory
  Woods__Storage__Snapshotter -->|construction: new| Woods__MCP__UnsupportedArtifact
  Woods__Storage__Snapshotter -->|construction: new| Woods__MCP__UnsupportedArtifact
  Woods__Storage__Snapshotter -->|construction: new| Woods__MCP__DimensionMismatch
  Woods__Storage__Snapshotter -->|construction: new| String
  Woods__Storage__Snapshotter -->|construction: new| String
  Woods__Storage__Snapshotter -->|construction: new| Tempfile
  Woods__Storage__Snapshotter__Vector(["new"])
  Woods__Storage__Snapshotter__Vector -->|construction: new| Pathname
  Woods__Storage__Snapshotter__Vector -->|construction: new| VectorStore__InMemory
  Woods__Storage__Snapshotter__Vector -->|construction: new| Woods__MCP__MissingArtifact
  Woods__Storage__Snapshotter__Vector -->|serialization: to_a| store_each_entry
  Woods__Storage__Snapshotter__Vector -->|construction: new| Pathname
  Woods__Storage__Snapshotter__Vector -->|construction: new| Woods__MCP__UnsupportedArtifact
  Woods__Storage__Snapshotter__Vector -->|construction: new| Woods__MCP__UnsupportedArtifact
  Woods__Storage__Snapshotter__Vector -->|construction: new| VectorStore__InMemory
  Woods__Storage__Snapshotter__Vector -->|construction: new| Woods__MCP__UnsupportedArtifact
  Woods__Storage__Snapshotter__Vector -->|construction: new| Woods__MCP__UnsupportedArtifact
  Woods__Storage__Snapshotter__Vector -->|construction: new| Woods__MCP__DimensionMismatch
  Woods__Storage__Snapshotter__Vector -->|construction: new| String
  Woods__Storage__Snapshotter__Vector -->|construction: new| String
  Woods__Storage__Snapshotter__Vector -->|construction: new| Tempfile
  Woods__Storage__Snapshotter__Vector_load_dump_dir(["new"])
  Woods__Storage__Snapshotter__Vector_load_dump_dir -->|construction: new| Pathname
  Woods__Storage__Snapshotter__Vector_missing_dump_store(["new"])
  Woods__Storage__Snapshotter__Vector_missing_dump_store -->|construction: new| VectorStore__InMemory
  Woods__Storage__Snapshotter__Vector_missing_dump_store -->|construction: new| Woods__MCP__MissingArtifact
  Woods__Storage__Snapshotter__Vector_dump(["to_a"])
  Woods__Storage__Snapshotter__Vector_dump -->|serialization: to_a| store_each_entry
  Woods__Storage__Snapshotter__Vector_dump -->|construction: new| Pathname
  entries["entries"]
  Woods -->|serialization: to_a| entries
  Woods -->|construction: new| Struct
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  Woods -->|construction: new| SearchResult
  Woods__Storage -->|serialization: to_a| entries
  Woods__Storage -->|construction: new| Struct
  Woods__Storage -->|construction: new| Set
  Woods__Storage -->|construction: new| Set
  Woods__Storage -->|construction: new| SearchResult
  Woods__Storage__VectorStore -->|serialization: to_a| entries
  Woods__Storage__VectorStore -->|construction: new| Struct
  Woods__Storage__VectorStore -->|construction: new| Set
  Woods__Storage__VectorStore -->|construction: new| Set
  Woods__Storage__VectorStore -->|construction: new| SearchResult
  Woods__Storage__VectorStore__Interface[/"serialization"/]
  Woods__Storage__VectorStore__Interface -->|serialization: to_a| entries
  Woods__Storage__VectorStore__InMemory(["new"])
  Woods__Storage__VectorStore__InMemory -->|construction: new| Set
  Woods__Storage__VectorStore__InMemory -->|construction: new| Set
  Woods__Storage__VectorStore__InMemory -->|construction: new| SearchResult
  Woods__Storage__VectorStore__Interface_bulk_load[/"serialization"/]
  Woods__Storage__VectorStore__Interface_bulk_load -->|serialization: to_a| entries
  Woods__Storage__VectorStore__InMemory_initialize(["new"])
  Woods__Storage__VectorStore__InMemory_initialize -->|construction: new| Set
  Woods__Storage__VectorStore__InMemory_clear_(["new"])
  Woods__Storage__VectorStore__InMemory_clear_ -->|construction: new| Set
  Woods__Storage__VectorStore__InMemory_gather_candidates(["new"])
  Woods__Storage__VectorStore__InMemory_gather_candidates -->|construction: new| SearchResult
  Builder["Builder"]
  Woods -->|construction: new| Builder
  Embedding__Indexer["Embedding::Indexer"]
  Woods -->|construction: new| Embedding__Indexer
  Woods -->|construction: new| Woods__MCP__DimensionMismatch
  Woods__Tasks(["new"])
  Woods__Tasks -->|construction: new| Builder
  Woods__Tasks -->|construction: new| Embedding__Indexer
  Woods__Tasks -->|construction: new| Woods__MCP__DimensionMismatch
  Woods__Tasks_build_embed_indexer(["new"])
  Woods__Tasks_build_embed_indexer -->|construction: new| Builder
  Woods__Tasks_build_embed_indexer -->|construction: new| Embedding__Indexer
  Woods__Tasks_verify_store_dimensions_(["new"])
  Woods__Tasks_verify_store_dimensions_ -->|construction: new| Woods__MCP__DimensionMismatch
  unit_hashes_filter_map["unit_hashes.filter_map"]
  Woods -->|serialization: to_h| unit_hashes_filter_map
  Woods -->|deserialization: parse| JSON
  Woods__Temporal[/"serialization"/]
  Woods__Temporal -->|serialization: to_h| unit_hashes_filter_map
  Woods__Temporal -->|deserialization: parse| JSON
  Woods__Temporal__JsonSnapshotStore -->|serialization: to_h| unit_hashes_filter_map
  Woods__Temporal__JsonSnapshotStore -->|deserialization: parse| JSON
  Woods__Temporal__JsonSnapshotStore_index_units[/"serialization"/]
  Woods__Temporal__JsonSnapshotStore_index_units -->|serialization: to_h| unit_hashes_filter_map
  Woods__Temporal__JsonSnapshotStore_read_snapshot[\"deserialization"\]
  Woods__Temporal__JsonSnapshotStore_read_snapshot -->|deserialization: parse| JSON
  Woods -->|serialization: to_h| rows
  Woods__Temporal -->|serialization: to_h| rows
  Woods__Temporal__SnapshotStore -->|serialization: to_h| rows
  Woods__Temporal__SnapshotStore_load_snapshot_units[/"serialization"/]
  Woods__Temporal__SnapshotStore_load_snapshot_units -->|serialization: to_h| rows
  Woods -->|construction: new| Net__HTTP
  Woods -->|deserialization: parse| JSON
  Net__HTTP__Put["Net::HTTP::Put"]
  Woods -->|construction: new| Net__HTTP__Put
  Woods -->|construction: new| Net__HTTP__Post
  Woods -->|construction: new| Net__HTTP__Get
  Net__HTTP__Delete["Net::HTTP::Delete"]
  Woods -->|construction: new| Net__HTTP__Delete
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  ApiError["ApiError"]
  Woods -->|construction: new| ApiError
  Woods__Unblocked(["new"])
  Woods__Unblocked -->|construction: new| Net__HTTP
  Woods__Unblocked -->|deserialization: parse| JSON
  Woods__Unblocked -->|construction: new| Net__HTTP__Put
  Woods__Unblocked -->|construction: new| Net__HTTP__Post
  Woods__Unblocked -->|construction: new| Net__HTTP__Get
  Woods__Unblocked -->|construction: new| Net__HTTP__Delete
  Woods__Unblocked -->|deserialization: parse| JSON
  Woods__Unblocked -->|deserialization: parse| JSON
  Woods__Unblocked -->|construction: new| ApiError
  Woods__Unblocked__Client(["new"])
  Woods__Unblocked__Client -->|construction: new| Net__HTTP
  Woods__Unblocked__Client -->|deserialization: parse| JSON
  Woods__Unblocked__Client -->|construction: new| Net__HTTP__Put
  Woods__Unblocked__Client -->|construction: new| Net__HTTP__Post
  Woods__Unblocked__Client -->|construction: new| Net__HTTP__Get
  Woods__Unblocked__Client -->|construction: new| Net__HTTP__Delete
  Woods__Unblocked__Client -->|deserialization: parse| JSON
  Woods__Unblocked__Client -->|deserialization: parse| JSON
  Woods__Unblocked__Client -->|construction: new| ApiError
  Woods__Unblocked__Client_execute_http(["new"])
  Woods__Unblocked__Client_execute_http -->|construction: new| Net__HTTP
  Woods__Unblocked__Client_raise_ambiguous_response_error[\"deserialization"\]
  Woods__Unblocked__Client_raise_ambiguous_response_error -->|deserialization: parse| JSON
  Woods__Unblocked__Client_build_request(["new"])
  Woods__Unblocked__Client_build_request -->|construction: new| Net__HTTP__Put
  Woods__Unblocked__Client_build_request -->|construction: new| Net__HTTP__Post
  Woods__Unblocked__Client_build_request -->|construction: new| Net__HTTP__Get
  Woods__Unblocked__Client_build_request -->|construction: new| Net__HTTP__Delete
  Woods__Unblocked__Client_parse_response[\"deserialization"\]
  Woods__Unblocked__Client_parse_response -->|deserialization: parse| JSON
  Woods__Unblocked__Client_raise_api_error(["parse"])
  Woods__Unblocked__Client_raise_api_error -->|deserialization: parse| JSON
  Woods__Unblocked__Client_raise_api_error -->|construction: new| ApiError
  Woods -->|construction: new| Woods__Console__CredentialScanner
  Woods -->|construction: new| Woods__Export__UnitFacts
  Woods -->|construction: new| Woods__Export__UnitFacts
  Woods__Unblocked -->|construction: new| Woods__Console__CredentialScanner
  Woods__Unblocked -->|construction: new| Woods__Export__UnitFacts
  Woods__Unblocked -->|construction: new| Woods__Export__UnitFacts
  Woods__Unblocked__DocumentBuilder(["new"])
  Woods__Unblocked__DocumentBuilder -->|construction: new| Woods__Console__CredentialScanner
  Woods__Unblocked__DocumentBuilder -->|construction: new| Woods__Export__UnitFacts
  Woods__Unblocked__DocumentBuilder -->|construction: new| Woods__Export__UnitFacts
  Woods__Unblocked__DocumentBuilder_credential_scanner(["new"])
  Woods__Unblocked__DocumentBuilder_credential_scanner -->|construction: new| Woods__Console__CredentialScanner
  Woods__Unblocked__DocumentBuilder_model_associations(["new"])
  Woods__Unblocked__DocumentBuilder_model_associations -->|construction: new| Woods__Export__UnitFacts
  Woods__Unblocked__DocumentBuilder_model_schema_highlights(["new"])
  Woods__Unblocked__DocumentBuilder_model_schema_highlights -->|construction: new| Woods__Export__UnitFacts
  RateLimiter["RateLimiter"]
  Woods -->|construction: new| RateLimiter
  Woods -->|construction: new| Client
  DocumentBuilder["DocumentBuilder"]
  Woods -->|construction: new| DocumentBuilder
  Woods -->|construction: new| Set
  Woods -->|construction: new| Set
  _client_all_documents["@client.all_documents"]
  Woods -->|serialization: to_h| _client_all_documents
  Woods -->|construction: new| Hash
  Woods -->|construction: new| Woods__MCP__IndexReader
  Woods -->|construction: new| SyncManifest
  Woods__Unblocked -->|construction: new| RateLimiter
  Woods__Unblocked -->|construction: new| Client
  Woods__Unblocked -->|construction: new| DocumentBuilder
  Woods__Unblocked -->|construction: new| Set
  Woods__Unblocked -->|construction: new| Set
  Woods__Unblocked -->|serialization: to_h| _client_all_documents
  Woods__Unblocked -->|construction: new| Hash
  Woods__Unblocked -->|construction: new| Woods__MCP__IndexReader
  Woods__Unblocked -->|construction: new| SyncManifest
  Woods__Unblocked__Exporter(["new"])
  Woods__Unblocked__Exporter -->|construction: new| RateLimiter
  Woods__Unblocked__Exporter -->|construction: new| Client
  Woods__Unblocked__Exporter -->|construction: new| DocumentBuilder
  Woods__Unblocked__Exporter -->|construction: new| Set
  Woods__Unblocked__Exporter -->|construction: new| Set
  Woods__Unblocked__Exporter -->|serialization: to_h| _client_all_documents
  Woods__Unblocked__Exporter -->|construction: new| Hash
  Woods__Unblocked__Exporter -->|construction: new| Woods__MCP__IndexReader
  Woods__Unblocked__Exporter -->|construction: new| SyncManifest
  Woods__Unblocked__Exporter_initialize(["new"])
  Woods__Unblocked__Exporter_initialize -->|construction: new| RateLimiter
  Woods__Unblocked__Exporter_initialize -->|construction: new| Client
  Woods__Unblocked__Exporter_initialize -->|construction: new| DocumentBuilder
  Woods__Unblocked__Exporter_initialize -->|construction: new| Set
  Woods__Unblocked__Exporter_sync_all(["new"])
  Woods__Unblocked__Exporter_sync_all -->|construction: new| Set
  Woods__Unblocked__Exporter_resolve_missing_document_ids[/"serialization"/]
  Woods__Unblocked__Exporter_resolve_missing_document_ids -->|serialization: to_h| _client_all_documents
  Woods__Unblocked__Exporter_build_uri_index(["new"])
  Woods__Unblocked__Exporter_build_uri_index -->|construction: new| Hash
  Woods__Unblocked__Exporter_build_reader(["new"])
  Woods__Unblocked__Exporter_build_reader -->|construction: new| Woods__MCP__IndexReader
  Woods__Unblocked__Exporter_build_manifest(["new"])
  Woods__Unblocked__Exporter_build_manifest -->|construction: new| SyncManifest
  Woods -->|construction: new| Mutex
  Woods__Unblocked -->|construction: new| Mutex
  Woods__Unblocked__RateLimiter(["new"])
  Woods__Unblocked__RateLimiter -->|construction: new| Mutex
  Woods__Unblocked__RateLimiter_initialize(["new"])
  Woods__Unblocked__RateLimiter_initialize -->|construction: new| Mutex
  current_uris["current_uris"]
  Woods -->|serialization: to_a| current_uris
  Woods -->|deserialization: parse| JSON
  Woods__Unblocked -->|serialization: to_a| current_uris
  Woods__Unblocked -->|deserialization: parse| JSON
  Woods__Unblocked__SyncManifest[/"serialization"/]
  Woods__Unblocked__SyncManifest -->|serialization: to_a| current_uris
  Woods__Unblocked__SyncManifest -->|deserialization: parse| JSON
  Woods__Unblocked__SyncManifest_stale_uris[/"serialization"/]
  Woods__Unblocked__SyncManifest_stale_uris -->|serialization: to_a| current_uris
  Woods__Unblocked__SyncManifest_load[\"deserialization"\]
  Woods__Unblocked__SyncManifest_load -->|deserialization: parse| JSON
  Woods -->|construction: new| Gem__Version
  Woods -->|construction: new| Gem__Version
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| JSON
  Woods__UpdateCheck(["new"])
  Woods__UpdateCheck -->|construction: new| Gem__Version
  Woods__UpdateCheck -->|construction: new| Gem__Version
  Woods__UpdateCheck -->|deserialization: parse| JSON
  Woods__UpdateCheck -->|deserialization: parse| JSON
  Woods__UpdateCheck_newer_(["new"])
  Woods__UpdateCheck_newer_ -->|construction: new| Gem__Version
  Woods__UpdateCheck_newer_ -->|construction: new| Gem__Version
  Woods__UpdateCheck_read_cache[\"deserialization"\]
  Woods__UpdateCheck_read_cache -->|deserialization: parse| JSON
  Woods__UpdateCheck_fetch_latest_version[\"deserialization"\]
  Woods__UpdateCheck_fetch_latest_version -->|deserialization: parse| JSON
  Woods -->|construction: new| Woods__Extractor
  RailsReloader["RailsReloader"]
  Woods -->|construction: new| RailsReloader
  Woods -->|construction: new| Generation
  Status["Status"]
  Woods -->|construction: new| Status
  Woods -->|construction: new| ChangeSet
  Woods -->|construction: new| Thread
  Woods -->|construction: new| Coordination__PipelineLock
  Woods -->|construction: new| Set
  Woods -->|construction: new| Mutex
  Woods -->|construction: new| Mutex
  Woods -->|construction: new| ChangeSet
  _pending["@pending"]
  Woods -->|serialization: to_a| _pending
  Woods -->|construction: new| Set
  Woods -->|serialization: to_a| _pending
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| Woods__Generation
  Woods -->|deserialization: parse| JSON
  Woods -->|construction: new| ChangeSet
  Woods -->|construction: new| Thread
  Woods -->|deserialization: parse| JSON
  NullLogger["NullLogger"]
  Woods -->|construction: new| NullLogger
  Woods__Watch(["new"])
  Woods__Watch -->|construction: new| Woods__Extractor
  Woods__Watch -->|construction: new| RailsReloader
  Woods__Watch -->|construction: new| Generation
  Woods__Watch -->|construction: new| Status
  Woods__Watch -->|construction: new| ChangeSet
  Woods__Watch -->|construction: new| Thread
  Woods__Watch -->|construction: new| Coordination__PipelineLock
  Woods__Watch -->|construction: new| Set
  Woods__Watch -->|construction: new| Mutex
  Woods__Watch -->|construction: new| Mutex
  Woods__Watch -->|construction: new| ChangeSet
  Woods__Watch -->|serialization: to_a| _pending
  Woods__Watch -->|construction: new| Set
  Woods__Watch -->|serialization: to_a| _pending
  Woods__Watch -->|deserialization: parse| JSON
  Woods__Watch -->|construction: new| Woods__Generation
  Woods__Watch -->|deserialization: parse| JSON
  Woods__Watch -->|construction: new| ChangeSet
  Woods__Watch -->|construction: new| Thread
  Woods__Watch -->|deserialization: parse| JSON
  Woods__Watch -->|construction: new| NullLogger
  Woods__Watch__Daemon(["new"])
  Woods__Watch__Daemon -->|construction: new| Woods__Extractor
  Woods__Watch__Daemon -->|construction: new| RailsReloader
  Woods__Watch__Daemon -->|construction: new| Generation
  Woods__Watch__Daemon -->|construction: new| Status
  Woods__Watch__Daemon -->|construction: new| ChangeSet
  Woods__Watch__Daemon -->|construction: new| Thread
  Woods__Watch__Daemon -->|construction: new| Coordination__PipelineLock
  Woods__Watch__Daemon -->|construction: new| Set
  Woods__Watch__Daemon -->|construction: new| Mutex
  Woods__Watch__Daemon -->|construction: new| Mutex
  Woods__Watch__Daemon -->|construction: new| ChangeSet
  Woods__Watch__Daemon -->|serialization: to_a| _pending
  Woods__Watch__Daemon -->|construction: new| Set
  Woods__Watch__Daemon -->|serialization: to_a| _pending
  Woods__Watch__Daemon -->|deserialization: parse| JSON
  Woods__Watch__Daemon -->|construction: new| Woods__Generation
  Woods__Watch__Daemon -->|deserialization: parse| JSON
  Woods__Watch__Daemon -->|construction: new| ChangeSet
  Woods__Watch__Daemon -->|construction: new| Thread
  Woods__Watch__Daemon -->|deserialization: parse| JSON
  Woods__Watch__Daemon -->|construction: new| NullLogger
  Woods__Watch__Daemon_initialize(["new"])
  Woods__Watch__Daemon_initialize -->|construction: new| Woods__Extractor
  Woods__Watch__Daemon_initialize -->|construction: new| RailsReloader
  Woods__Watch__Daemon_initialize -->|construction: new| Generation
  Woods__Watch__Daemon_initialize -->|construction: new| Status
  Woods__Watch__Daemon_process(["new"])
  Woods__Watch__Daemon_process -->|construction: new| ChangeSet
  Woods__Watch__Daemon_launch_watcher(["new"])
  Woods__Watch__Daemon_launch_watcher -->|construction: new| Thread
  Woods__Watch__Daemon_default_lock(["new"])
  Woods__Watch__Daemon_default_lock -->|construction: new| Coordination__PipelineLock
  Woods__Watch__Daemon_reset_cycle_state(["new"])
  Woods__Watch__Daemon_reset_cycle_state -->|construction: new| Set
  Woods__Watch__Daemon_reset_cycle_state -->|construction: new| Mutex
  Woods__Watch__Daemon_reset_cycle_state -->|construction: new| Mutex
  Woods__Watch__Daemon_enqueue(["new"])
  Woods__Watch__Daemon_enqueue -->|construction: new| ChangeSet
  Woods__Watch__Daemon_drain_with(["to_a"])
  Woods__Watch__Daemon_drain_with -->|serialization: to_a| _pending
  Woods__Watch__Daemon_drain_with -->|construction: new| Set
  Woods__Watch__Daemon_persist_pending[/"serialization"/]
  Woods__Watch__Daemon_persist_pending -->|serialization: to_a| _pending
  Woods__Watch__Daemon_restore_pending[\"deserialization"\]
  Woods__Watch__Daemon_restore_pending -->|deserialization: parse| JSON
  Woods__Watch__Daemon_persisted_registered_paths(["new"])
  Woods__Watch__Daemon_persisted_registered_paths -->|construction: new| Woods__Generation
  Woods__Watch__Daemon_persisted_registered_paths -->|deserialization: parse| JSON
  Woods__Watch__Daemon_reconcile_deletions(["new"])
  Woods__Watch__Daemon_reconcile_deletions -->|construction: new| ChangeSet
  Woods__Watch__Daemon_start_heartbeat(["new"])
  Woods__Watch__Daemon_start_heartbeat -->|construction: new| Thread
  Woods__Watch__Daemon_stale_claim_[\"deserialization"\]
  Woods__Watch__Daemon_stale_claim_ -->|deserialization: parse| JSON
  Woods__Watch__Daemon_default_logger(["new"])
  Woods__Watch__Daemon_default_logger -->|construction: new| NullLogger
  Woods -->|deserialization: parse| JSON
  Woods -->|deserialization: parse| Time
  Woods -->|deserialization: parse| Time
  Woods__Watch -->|deserialization: parse| JSON
  Woods__Watch -->|deserialization: parse| Time
  Woods__Watch -->|deserialization: parse| Time
  Woods__Watch__Status -->|deserialization: parse| JSON
  Woods__Watch__Status -->|deserialization: parse| Time
  Woods__Watch__Status -->|deserialization: parse| Time
  Woods__Watch__Status_read[\"deserialization"\]
  Woods__Watch__Status_read -->|deserialization: parse| JSON
  Woods__Watch__Status_recent_[\"deserialization"\]
  Woods__Watch__Status_recent_ -->|deserialization: parse| Time
  Woods__Watch__Status_recent_ -->|deserialization: parse| Time
  Woods -->|construction: new| Set
  Woods__Watch -->|construction: new| Set
  Woods__Watch__TreeScan(["new"])
  Woods__Watch__TreeScan -->|construction: new| Set
  Woods__Watch__TreeScan_each_file(["new"])
  Woods__Watch__TreeScan_each_file -->|construction: new| Set
  ListenWatcher["ListenWatcher"]
  Woods -->|construction: new| ListenWatcher
  PollingWatcher["PollingWatcher"]
  Woods -->|construction: new| PollingWatcher
  Woods__Watch -->|construction: new| ListenWatcher
  Woods__Watch -->|construction: new| PollingWatcher
  Woods__Watch__Watcher(["new"])
  Woods__Watch__Watcher -->|construction: new| ListenWatcher
  Woods__Watch__Watcher -->|construction: new| PollingWatcher
  Woods__Watch__Watcher_build(["new"])
  Woods__Watch__Watcher_build -->|construction: new| ListenWatcher
  Woods__Watch__Watcher_build -->|construction: new| PollingWatcher
```
