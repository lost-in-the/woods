# Call Graph

```mermaid
graph TD
  Woods["Woods"]
  Woods__Ast["Woods::Ast"]
  Woods__Ast__CallSiteExtractor["Woods::Ast::CallSiteExtractor"]
  Woods__Ast__CallSiteExtractor_extract["Woods::Ast::CallSiteExtractor#extract"]
  Woods__Ast__CallSiteExtractor_collect_calls["Woods::Ast::CallSiteExtractor#collect_calls"]
  Woods__Ast__MethodExtractor["Woods::Ast::MethodExtractor"]
  SourceSpan["SourceSpan"]
  Woods__Ast__MethodExtractor -->|include| SourceSpan
  Woods__Ast__MethodExtractor_initialize["Woods::Ast::MethodExtractor#initialize"]
  Parser["Parser"]
  Woods__Ast__MethodExtractor_initialize -->|method_call| Parser
  Woods__Ast__MethodExtractor_extract_method["Woods::Ast::MethodExtractor#extract_method"]
  Woods__Ast__MethodExtractor_extract_method_source["Woods::Ast::MethodExtractor#extract_method_source"]
  Woods__Ast__SourceSpan["Woods::Ast::SourceSpan"]
  Woods__Ast__SourceSpan_extract_source_span["Woods::Ast::SourceSpan#extract_source_span"]
  Woods__Error["Woods::Error"]
  StandardError["StandardError"]
  Woods__Error -->|inheritance| StandardError
  Woods__ExtractionError["Woods::ExtractionError"]
  Error["Error"]
  Woods__ExtractionError -->|inheritance| Error
  Woods__Ast__Parser["Woods::Ast::Parser"]
  Woods__Ast__Parser -->|include| SourceSpan
  Woods__Ast__Parser_parse["Woods::Ast::Parser#parse"]
  Woods__Ast__Parser_prism_available_["Woods::Ast::Parser#prism_available?"]
  Woods__Ast__Parser_parse_with_prism["Woods::Ast::Parser#parse_with_prism"]
  Prism["Prism"]
  Woods__Ast__Parser_parse_with_prism -->|method_call| Prism
  Woods__Ast__Parser_parse_with_parser_gem["Woods::Ast::Parser#parse_with_parser_gem"]
  Parser__Source__Buffer["Parser::Source::Buffer"]
  Woods__Ast__Parser_parse_with_parser_gem -->|method_call| Parser__Source__Buffer
  Parser__CurrentRuby["Parser::CurrentRuby"]
  Woods__Ast__Parser_parse_with_parser_gem -->|method_call| Parser__CurrentRuby
  Woods__Ast__Parser_convert_prism_node["Woods::Ast::Parser#convert_prism_node"]
  Node["Node"]
  Woods__Ast__Parser_convert_prism_node -->|method_call| Node
  Woods__Ast__Parser_convert_prism_class["Woods::Ast::Parser#convert_prism_class"]
  Woods__Ast__Parser_convert_prism_class -->|method_call| Node
  Woods__Ast__Parser_convert_prism_module["Woods::Ast::Parser#convert_prism_module"]
  Woods__Ast__Parser_convert_prism_module -->|method_call| Node
  Woods__Ast__Parser_convert_prism_def["Woods::Ast::Parser#convert_prism_def"]
  Woods__Ast__Parser_convert_prism_def -->|method_call| Node
  Woods__Ast__Parser_convert_prism_call["Woods::Ast::Parser#convert_prism_call"]
  Woods__Ast__Parser_convert_prism_call -->|method_call| Node
  Woods__Ast__Parser_convert_prism_constant_path["Woods::Ast::Parser#convert_prism_constant_path"]
  Woods__Ast__Parser_convert_prism_constant_path -->|method_call| Node
  Woods__Ast__Parser_convert_prism_if["Woods::Ast::Parser#convert_prism_if"]
  Woods__Ast__Parser_convert_prism_if -->|method_call| Node
  Woods__Ast__Parser_convert_prism_case["Woods::Ast::Parser#convert_prism_case"]
  Woods__Ast__Parser_convert_prism_case -->|method_call| Node
  Woods__Ast__Parser_extract_prism_body_children["Woods::Ast::Parser#extract_prism_body_children"]
  Woods__Ast__Parser_convert_prism_children["Woods::Ast::Parser#convert_prism_children"]
  Woods__Ast__Parser_extract_prism_generic_children["Woods::Ast::Parser#extract_prism_generic_children"]
  Woods__Ast__Parser_prism_else_clause["Woods::Ast::Parser#prism_else_clause"]
  Woods__Ast__Parser_line_for_prism["Woods::Ast::Parser#line_for_prism"]
  Woods__Ast__Parser_end_line_for_prism["Woods::Ast::Parser#end_line_for_prism"]
  Woods__Ast__Parser_extract_prism_source_span["Woods::Ast::Parser#extract_prism_source_span"]
  Woods__Ast__Parser_extract_prism_source_text["Woods::Ast::Parser#extract_prism_source_text"]
  Woods__Ast__Parser_extract_prism_receiver_text["Woods::Ast::Parser#extract_prism_receiver_text"]
  Woods__Ast__Parser_extract_const_path_text["Woods::Ast::Parser#extract_const_path_text"]
  Woods__Ast__Parser_extract_const_name["Woods::Ast::Parser#extract_const_name"]
  Woods__Ast__Parser_convert_parser_node["Woods::Ast::Parser#convert_parser_node"]
  Woods__Ast__Parser_convert_parser_node -->|method_call| Node
  Woods__Ast__Parser_parser_body_children["Woods::Ast::Parser#parser_body_children"]
  Woods__Ast__Parser_extract_parser_source_span["Woods::Ast::Parser#extract_parser_source_span"]
  Woods__Ast__Parser_extract_parser_source_text["Woods::Ast::Parser#extract_parser_source_text"]
  Woods__Ast__Parser_extract_parser_receiver_text["Woods::Ast::Parser#extract_parser_receiver_text"]
  Woods__Ast__Parser_extract_parser_const_name["Woods::Ast::Parser#extract_parser_const_name"]
  Woods__AtomicFile["Woods::AtomicFile"]
  Woods__AtomicFile_write["Woods::AtomicFile#write"]
  FileUtils["FileUtils"]
  Woods__AtomicFile_write -->|method_call| FileUtils
  Tempfile["Tempfile"]
  Woods__AtomicFile_write -->|method_call| Tempfile
  File["File"]
  Woods__AtomicFile_write -->|method_call| File
  Woods__AtomicFile_fsync_directory["Woods::AtomicFile#fsync_directory"]
  Woods__AtomicFile_fsync_directory -->|method_call| File
  Woods__AtomicFile_read["Woods::AtomicFile#read"]
  Woods__AtomicFile_read -->|method_call| File
  Woods__Builder["Woods::Builder"]
  Woods__Builder_preset_config["Woods::Builder.preset_config"]
  PRESETS["PRESETS"]
  Woods__Builder_preset_config -->|method_call| PRESETS
  Configuration["Configuration"]
  Woods__Builder_preset_config -->|method_call| Configuration
  Woods__Builder_initialize["Woods::Builder#initialize"]
  Woods__Builder_build_retriever["Woods::Builder#build_retriever"]
  Retriever["Retriever"]
  Woods__Builder_build_retriever -->|method_call| Retriever
  Woods__Builder_build_vector_store["Woods::Builder#build_vector_store"]
  Storage__VectorStore__InMemory["Storage::VectorStore::InMemory"]
  Woods__Builder_build_vector_store -->|method_call| Storage__VectorStore__InMemory
  Woods__Builder_vector_dimensions["Woods::Builder#vector_dimensions"]
  Woods__Builder_build_embedding_provider["Woods::Builder#build_embedding_provider"]
  Embedding__Provider__OpenAI["Embedding::Provider::OpenAI"]
  Woods__Builder_build_embedding_provider -->|method_call| Embedding__Provider__OpenAI
  Embedding__Provider__Ollama["Embedding::Provider::Ollama"]
  Woods__Builder_build_embedding_provider -->|method_call| Embedding__Provider__Ollama
  Woods__Builder_build_resilient_embedding_provider["Woods::Builder#build_resilient_embedding_provider"]
  Resilience__RetryableProvider["Resilience::RetryableProvider"]
  Woods__Builder_build_resilient_embedding_provider -->|method_call| Resilience__RetryableProvider
  Woods__Builder_provider_kwargs["Woods::Builder#provider_kwargs"]
  Woods__Builder_validate_provider_options_["Woods::Builder#validate_provider_options!"]
  PROVIDER_OPTION_KEYS["PROVIDER_OPTION_KEYS"]
  Woods__Builder_validate_provider_options_ -->|method_call| PROVIDER_OPTION_KEYS
  Woods__Builder_validate_required_provider_options_["Woods::Builder#validate_required_provider_options!"]
  Woods__Builder_apply_embedding_model_["Woods::Builder#apply_embedding_model!"]
  Woods__Builder_normalize_dimension_option_["Woods::Builder#normalize_dimension_option!"]
  Woods__Builder_conflicting_dimensions_["Woods::Builder#conflicting_dimensions?"]
  Woods__Builder_provider_object_["Woods::Builder#provider_object?"]
  Woods__Builder_build_fake_provider["Woods::Builder#build_fake_provider"]
  Embedding__Provider__Fake["Embedding::Provider::Fake"]
  Woods__Builder_build_fake_provider -->|method_call| Embedding__Provider__Fake
  Woods__Builder_build_text_preparer["Woods::Builder#build_text_preparer"]
  Embedding__TextPreparer["Embedding::TextPreparer"]
  Woods__Builder_build_text_preparer -->|method_call| Embedding__TextPreparer
  Woods__Builder_build_chunker["Woods::Builder#build_chunker"]
  Chunking__SemanticChunker["Chunking::SemanticChunker"]
  Woods__Builder_build_chunker -->|method_call| Chunking__SemanticChunker
  Woods__Builder_token_counter_for["Woods::Builder#token_counter_for"]
  Embedding__TokenCounter["Embedding::TokenCounter"]
  Woods__Builder_token_counter_for -->|method_call| Embedding__TokenCounter
  Woods__Builder_chars_per_token_for["Woods::Builder#chars_per_token_for"]
  TokenUtils["TokenUtils"]
  Woods__Builder_chars_per_token_for -->|method_call| TokenUtils
  Woods__Builder_safe_max_input_tokens["Woods::Builder#safe_max_input_tokens"]
  Woods__Builder_unwrap_provider["Woods::Builder#unwrap_provider"]
  Woods__Builder_chunker_budget_message["Woods::Builder#chunker_budget_message"]
  Woods__Builder_build_metadata_store["Woods::Builder#build_metadata_store"]
  Storage__MetadataStore__InMemory["Storage::MetadataStore::InMemory"]
  Woods__Builder_build_metadata_store -->|method_call| Storage__MetadataStore__InMemory
  Storage__MetadataStore__SQLite["Storage::MetadataStore::SQLite"]
  Woods__Builder_build_metadata_store -->|method_call| Storage__MetadataStore__SQLite
  Woods__Builder_sqlite_metadata_options["Woods::Builder#sqlite_metadata_options"]
  Woods__Builder_sqlite_metadata_options -->|method_call| File
  Woods__Builder_build_graph_store["Woods::Builder#build_graph_store"]
  Storage__GraphStore__Memory["Storage::GraphStore::Memory"]
  Woods__Builder_build_graph_store -->|method_call| Storage__GraphStore__Memory
  Woods__Builder_build_pgvector_store["Woods::Builder#build_pgvector_store"]
  Storage__VectorStore__Pgvector["Storage::VectorStore::Pgvector"]
  Woods__Builder_build_pgvector_store -->|method_call| Storage__VectorStore__Pgvector
  Woods__Builder_verify_pgvector_dimensions_["Woods::Builder#verify_pgvector_dimensions!"]
  Woods__Builder_resolve_pgvector_dimensions["Woods::Builder#resolve_pgvector_dimensions"]
  Woods__Builder_build_qdrant_store["Woods::Builder#build_qdrant_store"]
  Storage__VectorStore__Qdrant["Storage::VectorStore::Qdrant"]
  Woods__Builder_build_qdrant_store -->|method_call| Storage__VectorStore__Qdrant
  Woods__Builder_validate_required_store_options_["Woods::Builder#validate_required_store_options!"]
  Woods__Builder_resolve_qdrant_dimensions["Woods::Builder#resolve_qdrant_dimensions"]
  Woods__Builder_build_cache_store["Woods::Builder#build_cache_store"]
  Cache__InMemory["Cache::InMemory"]
  Woods__Builder_build_cache_store -->|method_call| Cache__InMemory
  Cache__RedisCacheStore["Cache::RedisCacheStore"]
  Woods__Builder_build_cache_store -->|method_call| Cache__RedisCacheStore
  Cache__SolidCacheStore["Cache::SolidCacheStore"]
  Woods__Builder_build_cache_store -->|method_call| Cache__SolidCacheStore
  Woods__Builder_wrap_with_embedding_cache["Woods::Builder#wrap_with_embedding_cache"]
  Cache__CachedEmbeddingProvider["Cache::CachedEmbeddingProvider"]
  Woods__Builder_wrap_with_embedding_cache -->|method_call| Cache__CachedEmbeddingProvider
  Woods__Builder_wrap_with_retriever_cache["Woods::Builder#wrap_with_retriever_cache"]
  Cache__CachedRetriever["Cache::CachedRetriever"]
  Woods__Builder_wrap_with_retriever_cache -->|method_call| Cache__CachedRetriever
  Woods__Cache["Woods::Cache"]
  Woods__Cache__OwnerAbortedError["Woods::Cache::OwnerAbortedError"]
  Woods__Cache__OwnerAbortedError -->|inheritance| StandardError
  Woods__Cache__InflightEntry["Woods::Cache::InflightEntry"]
  Woods__Cache__CachedEmbeddingProvider["Woods::Cache::CachedEmbeddingProvider"]
  Embedding__Provider__Interface["Embedding::Provider::Interface"]
  Woods__Cache__CachedEmbeddingProvider -->|include| Embedding__Provider__Interface
  Woods__Cache__CachedRetriever["Woods::Cache::CachedRetriever"]
  Woods__Cache__OwnerAbortedError_initialize["Woods::Cache::OwnerAbortedError#initialize"]
  Woods__Cache__InflightEntry_initialize["Woods::Cache::InflightEntry#initialize"]
  Mutex["Mutex"]
  Woods__Cache__InflightEntry_initialize -->|method_call| Mutex
  ConditionVariable["ConditionVariable"]
  Woods__Cache__InflightEntry_initialize -->|method_call| ConditionVariable
  Woods__Cache__InflightEntry_fulfill["Woods::Cache::InflightEntry#fulfill"]
  Woods__Cache__InflightEntry_reject["Woods::Cache::InflightEntry#reject"]
  Woods__Cache__InflightEntry_await["Woods::Cache::InflightEntry#await"]
  Woods__Cache__InflightEntry_waiter_count["Woods::Cache::InflightEntry#waiter_count"]
  Woods__Cache__CachedEmbeddingProvider_initialize["Woods::Cache::CachedEmbeddingProvider#initialize"]
  Woods__Cache__CachedEmbeddingProvider_initialize -->|method_call| Mutex
  Woods__Cache__CachedEmbeddingProvider_embed["Woods::Cache::CachedEmbeddingProvider#embed"]
  Woods__Cache__CachedEmbeddingProvider_embed_batch["Woods::Cache::CachedEmbeddingProvider#embed_batch"]
  Woods__Cache__CachedEmbeddingProvider_dimensions["Woods::Cache::CachedEmbeddingProvider#dimensions"]
  Woods__Cache__CachedEmbeddingProvider_model_name["Woods::Cache::CachedEmbeddingProvider#model_name"]
  Woods__Cache__CachedEmbeddingProvider_max_input_tokens["Woods::Cache::CachedEmbeddingProvider#max_input_tokens"]
  Woods__Cache__CachedEmbeddingProvider_with_single_flight["Woods::Cache::CachedEmbeddingProvider#with_single_flight"]
  Woods__Cache__CachedEmbeddingProvider_claim_single["Woods::Cache::CachedEmbeddingProvider#claim_single"]
  InflightEntry["InflightEntry"]
  Woods__Cache__CachedEmbeddingProvider_claim_single -->|method_call| InflightEntry
  Woods__Cache__CachedEmbeddingProvider_claim_inflight["Woods::Cache::CachedEmbeddingProvider#claim_inflight"]
  Woods__Cache__CachedEmbeddingProvider_claim_inflight -->|method_call| InflightEntry
  Woods__Cache__CachedEmbeddingProvider_fetch_and_fulfill["Woods::Cache::CachedEmbeddingProvider#fetch_and_fulfill"]
  Woods__Cache__CachedEmbeddingProvider_await_others["Woods::Cache::CachedEmbeddingProvider#await_others"]
  Woods__Cache__CachedEmbeddingProvider_clear_inflight["Woods::Cache::CachedEmbeddingProvider#clear_inflight"]
  Woods__Cache__CachedEmbeddingProvider_write_cache["Woods::Cache::CachedEmbeddingProvider#write_cache"]
  Woods__Cache__CachedEmbeddingProvider_partition_cached["Woods::Cache::CachedEmbeddingProvider#partition_cached"]
  Array["Array"]
  Woods__Cache__CachedEmbeddingProvider_partition_cached -->|method_call| Array
  Woods__Cache__CachedEmbeddingProvider_embedding_key["Woods::Cache::CachedEmbeddingProvider#embedding_key"]
  Cache["Cache"]
  Woods__Cache__CachedEmbeddingProvider_embedding_key -->|method_call| Cache
  Woods__Cache__CachedRetriever_initialize["Woods::Cache::CachedRetriever#initialize"]
  Woods__Cache__CachedRetriever_vector_store["Woods::Cache::CachedRetriever#vector_store"]
  Woods__Cache__CachedRetriever_metadata_store["Woods::Cache::CachedRetriever#metadata_store"]
  Woods__Cache__CachedRetriever_graph_store["Woods::Cache::CachedRetriever#graph_store"]
  Woods__Cache__CachedRetriever_invalidate_context_cache_["Woods::Cache::CachedRetriever#invalidate_context_cache!"]
  Woods__Cache__CachedRetriever_retrieve["Woods::Cache::CachedRetriever#retrieve"]
  Woods__Cache__CachedRetriever_context_key["Woods::Cache::CachedRetriever#context_key"]
  Woods__Cache__CachedRetriever_context_key -->|method_call| Cache
  Woods__Cache__CachedRetriever_fingerprint["Woods::Cache::CachedRetriever#fingerprint"]
  Woods__Cache__CachedRetriever_rehydrate_cached["Woods::Cache::CachedRetriever#rehydrate_cached"]
  Retriever__RetrievalResult["Retriever::RetrievalResult"]
  Woods__Cache__CachedRetriever_rehydrate_cached -->|method_call| Retriever__RetrievalResult
  Woods__Cache__CachedRetriever_serialize_result["Woods::Cache::CachedRetriever#serialize_result"]
  Woods__Cache__CachedRetriever_serialize_type_rank_context["Woods::Cache::CachedRetriever#serialize_type_rank_context"]
  Woods__Cache__CachedRetriever_rehydrate_type_rank_context["Woods::Cache::CachedRetriever#rehydrate_type_rank_context"]
  Woods__Cache__CacheStore["Woods::Cache::CacheStore"]
  Woods__Cache__InMemory["Woods::Cache::InMemory"]
  CacheStore["CacheStore"]
  Woods__Cache__InMemory -->|inheritance| CacheStore
  Woods__Cache_cache_key["Woods::Cache.cache_key"]
  Digest__SHA256["Digest::SHA256"]
  Woods__Cache_cache_key -->|method_call| Digest__SHA256
  Woods__Cache__CacheStore_read["Woods::Cache::CacheStore#read"]
  Woods__Cache__CacheStore_write["Woods::Cache::CacheStore#write"]
  Woods__Cache__CacheStore_delete["Woods::Cache::CacheStore#delete"]
  Woods__Cache__CacheStore_exist_["Woods::Cache::CacheStore#exist?"]
  Woods__Cache__CacheStore_clear["Woods::Cache::CacheStore#clear"]
  Woods__Cache__CacheStore_fetch["Woods::Cache::CacheStore#fetch"]
  Woods__Cache__CacheStore_logger["Woods::Cache::CacheStore#logger"]
  Rails["Rails"]
  Woods__Cache__CacheStore_logger -->|method_call| Rails
  Logger["Logger"]
  Woods__Cache__CacheStore_logger -->|method_call| Logger
  Woods__Cache__CacheStore_clear_pattern["Woods::Cache::CacheStore#clear_pattern"]
  Woods__Cache__CacheStore_delete_silently["Woods::Cache::CacheStore#delete_silently"]
  Woods__Cache__InMemory_initialize["Woods::Cache::InMemory#initialize"]
  Woods__Cache__InMemory_initialize -->|method_call| Mutex
  Woods__Cache__InMemory_read["Woods::Cache::InMemory#read"]
  Time_now["Time.now"]
  Woods__Cache__InMemory_read -->|method_call| Time_now
  Time["Time"]
  Woods__Cache__InMemory_read -->|method_call| Time
  Woods__Cache__InMemory_write["Woods::Cache::InMemory#write"]
  Woods__Cache__InMemory_write -->|method_call| Time_now
  Woods__Cache__InMemory_write -->|method_call| Time
  Woods__Cache__InMemory_delete["Woods::Cache::InMemory#delete"]
  Woods__Cache__InMemory_exist_["Woods::Cache::InMemory#exist?"]
  Woods__Cache__InMemory_exist_ -->|method_call| Time_now
  Woods__Cache__InMemory_exist_ -->|method_call| Time
  Woods__Cache__InMemory_clear["Woods::Cache::InMemory#clear"]
  Woods__Cache__InMemory_size["Woods::Cache::InMemory#size"]
  Woods__Cache__InMemory_evict_key["Woods::Cache::InMemory#evict_key"]
  Woods__Cache__InMemory_touch["Woods::Cache::InMemory#touch"]
  Woods__Cache__RedisCacheStore["Woods::Cache::RedisCacheStore"]
  Woods__Cache__RedisCacheStore -->|inheritance| CacheStore
  Woods__Cache__RedisCacheStore_initialize["Woods::Cache::RedisCacheStore#initialize"]
  Woods__Cache__RedisCacheStore_read["Woods::Cache::RedisCacheStore#read"]
  JSON["JSON"]
  Woods__Cache__RedisCacheStore_read -->|method_call| JSON
  Woods__Cache__RedisCacheStore_write["Woods::Cache::RedisCacheStore#write"]
  Woods__Cache__RedisCacheStore_write -->|method_call| JSON
  Woods__Cache__RedisCacheStore_delete["Woods::Cache::RedisCacheStore#delete"]
  Woods__Cache__RedisCacheStore_exist_["Woods::Cache::RedisCacheStore#exist?"]
  Woods__Cache__RedisCacheStore_clear["Woods::Cache::RedisCacheStore#clear"]
  Woods__Cache__SolidCacheStore["Woods::Cache::SolidCacheStore"]
  Woods__Cache__SolidCacheStore -->|inheritance| CacheStore
  Woods__Cache__SolidCacheStore_initialize["Woods::Cache::SolidCacheStore#initialize"]
  Woods__Cache__SolidCacheStore_read["Woods::Cache::SolidCacheStore#read"]
  Woods__Cache__SolidCacheStore_read -->|method_call| JSON
  Woods__Cache__SolidCacheStore_write["Woods::Cache::SolidCacheStore#write"]
  Woods__Cache__SolidCacheStore_write -->|method_call| JSON
  Woods__Cache__SolidCacheStore_delete["Woods::Cache::SolidCacheStore#delete"]
  Woods__Cache__SolidCacheStore_exist_["Woods::Cache::SolidCacheStore#exist?"]
  Woods__Cache__SolidCacheStore_clear["Woods::Cache::SolidCacheStore#clear"]
  Woods__ChangeSet["Woods::ChangeSet"]
  Woods__ChangeSet_initialize["Woods::ChangeSet#initialize"]
  Pathname["Pathname"]
  Woods__ChangeSet_initialize -->|method_call| Pathname
  Array_filter_map_uniq["Array.filter_map.uniq"]
  Woods__ChangeSet_initialize -->|method_call| Array_filter_map_uniq
  Array_filter_map["Array.filter_map"]
  Woods__ChangeSet_initialize -->|method_call| Array_filter_map
  Woods__ChangeSet_initialize -->|method_call| Array
  Woods__ChangeSet_relative_paths["Woods::ChangeSet#relative_paths"]
  Woods__ChangeSet_existing_paths["Woods::ChangeSet#existing_paths"]
  Woods__ChangeSet_existing_paths -->|method_call| File
  Woods__ChangeSet_missing_paths["Woods::ChangeSet#missing_paths"]
  Woods__ChangeSet_empty_["Woods::ChangeSet#empty?"]
  Woods__ChangeSet_size["Woods::ChangeSet#size"]
  Woods__ChangeSet_relativize["Woods::ChangeSet#relativize"]
  Woods__ChangeSet_absolutize["Woods::ChangeSet#absolutize"]
  Pathname_new["Pathname.new"]
  Woods__ChangeSet_absolutize -->|method_call| Pathname_new
  Woods__ChangeSet_absolutize -->|method_call| Pathname
  Woods__Chunking["Woods::Chunking"]
  Woods__Chunking__Chunk["Woods::Chunking::Chunk"]
  Woods__Chunking__Chunk_initialize["Woods::Chunking::Chunk#initialize"]
  Woods__Chunking__Chunk_token_count["Woods::Chunking::Chunk#token_count"]
  Woods__Chunking__Chunk_content_hash["Woods::Chunking::Chunk#content_hash"]
  Woods__Chunking__Chunk_content_hash -->|method_call| Digest__SHA256
  Woods__Chunking__Chunk_identifier["Woods::Chunking::Chunk#identifier"]
  Woods__Chunking__Chunk_empty_["Woods::Chunking::Chunk#empty?"]
  Woods__Chunking__Chunk_to_h["Woods::Chunking::Chunk#to_h"]
  Woods__Chunking__ChunkBuilder["Woods::Chunking::ChunkBuilder"]
  Woods__Chunking__LineDepthTracking["Woods::Chunking::LineDepthTracking"]
  Woods__Chunking__SemanticChunker["Woods::Chunking::SemanticChunker"]
  Woods__Chunking__ModelChunker["Woods::Chunking::ModelChunker"]
  ChunkBuilder["ChunkBuilder"]
  Woods__Chunking__ModelChunker -->|include| ChunkBuilder
  LineDepthTracking["LineDepthTracking"]
  Woods__Chunking__ModelChunker -->|include| LineDepthTracking
  Woods__Chunking__ControllerChunker["Woods::Chunking::ControllerChunker"]
  Woods__Chunking__ControllerChunker -->|include| ChunkBuilder
  Woods__Chunking__ControllerChunker -->|include| LineDepthTracking
  Woods__Chunking__MethodChunker["Woods::Chunking::MethodChunker"]
  Woods__Chunking__MethodChunker -->|include| ChunkBuilder
  Woods__Chunking__MethodChunker -->|include| LineDepthTracking
  Woods__Chunking__ChunkBuilder_build_chunk["Woods::Chunking::ChunkBuilder#build_chunk"]
  Chunk["Chunk"]
  Woods__Chunking__ChunkBuilder_build_chunk -->|method_call| Chunk
  Woods__Chunking__LineDepthTracking_block_opener_["Woods::Chunking::LineDepthTracking#block_opener?"]
  Woods__Chunking__LineDepthTracking_block_terminator_["Woods::Chunking::LineDepthTracking#block_terminator?"]
  Woods__Chunking__LineDepthTracking_endless_def_["Woods::Chunking::LineDepthTracking#endless_def?"]
  Woods__Chunking__LineDepthTracking_operator_def_name["Woods::Chunking::LineDepthTracking#operator_def_name"]
  Woods__Chunking__SemanticChunker_initialize["Woods::Chunking::SemanticChunker#initialize"]
  Woods__Chunking__SemanticChunker_chunk["Woods::Chunking::SemanticChunker#chunk"]
  Woods__Chunking__SemanticChunker_enforce_chunk_limits_["Woods::Chunking::SemanticChunker#enforce_chunk_limits!"]
  Woods__Chunking__SemanticChunker_enforcement_active_["Woods::Chunking::SemanticChunker#enforcement_active?"]
  Woods__Chunking__SemanticChunker_oversize_["Woods::Chunking::SemanticChunker#oversize?"]
  Woods__Chunking__SemanticChunker_tokenizer_active_["Woods::Chunking::SemanticChunker#tokenizer_active?"]
  Woods__Chunking__SemanticChunker_split_oversize_hash_chunk["Woods::Chunking::SemanticChunker#split_oversize_hash_chunk"]
  Woods__Chunking__SemanticChunker_chunks_for["Woods::Chunking::SemanticChunker#chunks_for"]
  ModelChunker_new["ModelChunker.new"]
  Woods__Chunking__SemanticChunker_chunks_for -->|method_call| ModelChunker_new
  ModelChunker["ModelChunker"]
  Woods__Chunking__SemanticChunker_chunks_for -->|method_call| ModelChunker
  ControllerChunker_new["ControllerChunker.new"]
  Woods__Chunking__SemanticChunker_chunks_for -->|method_call| ControllerChunker_new
  ControllerChunker["ControllerChunker"]
  Woods__Chunking__SemanticChunker_chunks_for -->|method_call| ControllerChunker
  METHOD_CHUNKABLE_TYPES["METHOD_CHUNKABLE_TYPES"]
  Woods__Chunking__SemanticChunker_chunks_for -->|method_call| METHOD_CHUNKABLE_TYPES
  MethodChunker_new["MethodChunker.new"]
  Woods__Chunking__SemanticChunker_chunks_for -->|method_call| MethodChunker_new
  MethodChunker["MethodChunker"]
  Woods__Chunking__SemanticChunker_chunks_for -->|method_call| MethodChunker
  Woods__Chunking__SemanticChunker_build_whole_chunk["Woods::Chunking::SemanticChunker#build_whole_chunk"]
  Woods__Chunking__SemanticChunker_build_whole_chunk -->|method_call| Chunk
  Woods__Chunking__SemanticChunker_enforce_char_limit["Woods::Chunking::SemanticChunker#enforce_char_limit"]
  Woods__Chunking__SemanticChunker_split_oversize_chunk["Woods::Chunking::SemanticChunker#split_oversize_chunk"]
  Woods__Chunking__SemanticChunker_split_oversize_chunk -->|method_call| Chunk
  Woods__Chunking__SemanticChunker_verified_slices["Woods::Chunking::SemanticChunker#verified_slices"]
  Woods__Chunking__SemanticChunker_verify_slice["Woods::Chunking::SemanticChunker#verify_slice"]
  Woods__Chunking__SemanticChunker_estimated_char_budget["Woods::Chunking::SemanticChunker#estimated_char_budget"]
  Woods__Chunking__SemanticChunker_slice_by_lines["Woods::Chunking::SemanticChunker#slice_by_lines"]
  String["String"]
  Woods__Chunking__SemanticChunker_slice_by_lines -->|method_call| String
  Woods__Chunking__ModelChunker_initialize["Woods::Chunking::ModelChunker#initialize"]
  Woods__Chunking__ModelChunker_chunk["Woods::Chunking::ModelChunker#chunk"]
  Woods__Chunking__ModelChunker_build_chunks["Woods::Chunking::ModelChunker#build_chunks"]
  SEMANTIC_SECTIONS["SEMANTIC_SECTIONS"]
  Woods__Chunking__ModelChunker_build_chunks -->|method_call| SEMANTIC_SECTIONS
  Woods__Chunking__ModelChunker_classify_lines["Woods::Chunking::ModelChunker#classify_lines"]
  Woods__Chunking__ModelChunker_empty_sections["Woods::Chunking::ModelChunker#empty_sections"]
  Woods__Chunking__ModelChunker_track_method_line["Woods::Chunking::ModelChunker#track_method_line"]
  Woods__Chunking__ModelChunker_update_method_depth["Woods::Chunking::ModelChunker#update_method_depth"]
  Woods__Chunking__ModelChunker_classify_line["Woods::Chunking::ModelChunker#classify_line"]
  Woods__Chunking__ModelChunker_detect_semantic_section["Woods::Chunking::ModelChunker#detect_semantic_section"]
  SECTION_PATTERNS["SECTION_PATTERNS"]
  Woods__Chunking__ModelChunker_detect_semantic_section -->|method_call| SECTION_PATTERNS
  Woods__Chunking__ModelChunker_start_method["Woods::Chunking::ModelChunker#start_method"]
  Woods__Chunking__ModelChunker_assign_fallback["Woods::Chunking::ModelChunker#assign_fallback"]
  Woods__Chunking__ControllerChunker_initialize["Woods::Chunking::ControllerChunker#initialize"]
  Woods__Chunking__ControllerChunker_chunk["Woods::Chunking::ControllerChunker#chunk"]
  Woods__Chunking__ControllerChunker_parse_lines["Woods::Chunking::ControllerChunker#parse_lines"]
  Woods__Chunking__ControllerChunker_track_action_line["Woods::Chunking::ControllerChunker#track_action_line"]
  Woods__Chunking__ControllerChunker_classify_controller_line["Woods::Chunking::ControllerChunker#classify_controller_line"]
  Woods__Chunking__ControllerChunker_start_action["Woods::Chunking::ControllerChunker#start_action"]
  Woods__Chunking__ControllerChunker_build_chunks["Woods::Chunking::ControllerChunker#build_chunks"]
  Woods__Chunking__MethodChunker_initialize["Woods::Chunking::MethodChunker#initialize"]
  Woods__Chunking__MethodChunker_chunk["Woods::Chunking::MethodChunker#chunk"]
  Woods__Chunking__MethodChunker_parse_lines["Woods::Chunking::MethodChunker#parse_lines"]
  Woods__Chunking__MethodChunker_track_method_line["Woods::Chunking::MethodChunker#track_method_line"]
  Woods__Chunking__MethodChunker_classify_top_level_line["Woods::Chunking::MethodChunker#classify_top_level_line"]
  Woods__Chunking__MethodChunker_start_method["Woods::Chunking::MethodChunker#start_method"]
  Woods__Chunking__MethodChunker_build_chunks["Woods::Chunking::MethodChunker#build_chunks"]
  Woods__Console["Woods::Console"]
  Woods__Console__AuditLogger["Woods::Console::AuditLogger"]
  Woods__Console__AuditLogger_initialize["Woods::Console::AuditLogger#initialize"]
  CredentialScanner["CredentialScanner"]
  Woods__Console__AuditLogger_initialize -->|method_call| CredentialScanner
  Woods__Console__AuditLogger_log["Woods::Console::AuditLogger#log"]
  Woods__Console__AuditLogger_log -->|method_call| File
  Woods__Console__AuditLogger_redact["Woods::Console::AuditLogger#redact"]
  Woods__Console__AuditLogger_truncate_deep["Woods::Console::AuditLogger#truncate_deep"]
  Woods__Console__AuditLogger_truncate_value["Woods::Console::AuditLogger#truncate_value"]
  Woods__Console__AuditLogger_sanitize_controls["Woods::Console::AuditLogger#sanitize_controls"]
  Woods__Console__AuditLogger_entries["Woods::Console::AuditLogger#entries"]
  Woods__Console__AuditLogger_entries -->|method_call| File
  File_readlines["File.readlines"]
  Woods__Console__AuditLogger_entries -->|method_call| File_readlines
  Woods__Console__AuditLogger_entries -->|method_call| JSON
  Woods__Console__AuditLogger_size["Woods::Console::AuditLogger#size"]
  Woods__Console__AuditLogger_ensure_directory_["Woods::Console::AuditLogger#ensure_directory!"]
  Woods__Console__AuditLogger_ensure_directory_ -->|method_call| File
  Woods__Console__AuditLogger_ensure_directory_ -->|method_call| FileUtils
  Woods__Console__BridgeProtocol["Woods::Console::BridgeProtocol"]
  Woods__Console__ConfirmationDeniedError["Woods::Console::ConfirmationDeniedError"]
  Woods__Console__ConfirmationDeniedError -->|inheritance| Woods__Error
  Woods__Console__Confirmation["Woods::Console::Confirmation"]
  Woods__Console__Confirmation_initialize["Woods::Console::Confirmation#initialize"]
  VALID_MODES["VALID_MODES"]
  Woods__Console__Confirmation_initialize -->|method_call| VALID_MODES
  Woods__Console__Confirmation_request_confirmation["Woods::Console::Confirmation#request_confirmation"]
  Woods__Console__Confirmation_evaluate["Woods::Console::Confirmation#evaluate"]
  Woods__Console__ConnectionError["Woods::Console::ConnectionError"]
  Woods__Console__ConnectionError -->|inheritance| Woods__Error
  Woods__Console__ConnectionManager["Woods::Console::ConnectionManager"]
  Woods__Console__ConnectionManager_initialize["Woods::Console::ConnectionManager#initialize"]
  Woods__Console__ConnectionManager_command["Woods::Console::ConnectionManager#command"]
  Woods__Console__ConnectionManager_replace_process_["Woods::Console::ConnectionManager#replace_process!"]
  Dir["Dir"]
  Woods__Console__ConnectionManager_replace_process_ -->|method_call| Dir
  Woods__Console__ConnectionManager_embedded_argv["Woods::Console::ConnectionManager#embedded_argv"]
  Woods__Console__ConnectionManager_docker_command["Woods::Console::ConnectionManager#docker_command"]
  Woods__Console__ConnectionManager_ssh_command["Woods::Console::ConnectionManager#ssh_command"]
  Woods__Console__ConsoleResponseRenderer["Woods::Console::ConsoleResponseRenderer"]
  MCP__ToolResponseRenderer["MCP::ToolResponseRenderer"]
  Woods__Console__ConsoleResponseRenderer -->|inheritance| MCP__ToolResponseRenderer
  Woods__Console__JsonConsoleRenderer["Woods::Console::JsonConsoleRenderer"]
  MCP__Renderers__JsonRenderer["MCP::Renderers::JsonRenderer"]
  Woods__Console__JsonConsoleRenderer -->|inheritance| MCP__Renderers__JsonRenderer
  Woods__Console__ConsoleResponseRenderer_render_default["Woods::Console::ConsoleResponseRenderer#render_default"]
  Woods__Console__ConsoleResponseRenderer_render_array["Woods::Console::ConsoleResponseRenderer#render_array"]
  Woods__Console__ConsoleResponseRenderer_render_table["Woods::Console::ConsoleResponseRenderer#render_table"]
  Woods__Console__ConsoleResponseRenderer_render_hash["Woods::Console::ConsoleResponseRenderer#render_hash"]
  Woods__Console__ConsoleResponseRenderer_render_hash_entry["Woods::Console::ConsoleResponseRenderer#render_hash_entry"]
  Woods__Console__ConsoleResponseRenderer_render_hash_array_value["Woods::Console::ConsoleResponseRenderer#render_hash_array_value"]
  POSITIONAL_ROW_KEYS["POSITIONAL_ROW_KEYS"]
  Woods__Console__ConsoleResponseRenderer_render_hash_array_value -->|method_call| POSITIONAL_ROW_KEYS
  Woods__Console__ConsoleResponseRenderer_render_positional_table["Woods::Console::ConsoleResponseRenderer#render_positional_table"]
  Woods__Console__ConsoleResponseRenderer_positional_row_values["Woods::Console::ConsoleResponseRenderer#positional_row_values"]
  Woods__Console__ConsoleResponseRenderer_header_row["Woods::Console::ConsoleResponseRenderer#header_row"]
  Woods__Console__ConsoleResponseRenderer_row_line["Woods::Console::ConsoleResponseRenderer#row_line"]
  Woods__Console__ConsoleResponseRenderer_stringify_array["Woods::Console::ConsoleResponseRenderer#stringify_array"]
  Woods__Console__CredentialIndex["Woods::Console::CredentialIndex"]
  Woods__Console__CredentialIndex_initialize["Woods::Console::CredentialIndex#initialize"]
  Woods__Console__CredentialIndex_initialize -->|method_call| Array
  Regexp["Regexp"]
  Woods__Console__CredentialIndex_initialize -->|method_call| Regexp
  Woods__Console__CredentialIndex_empty_["Woods::Console::CredentialIndex#empty?"]
  Woods__Console__CredentialIndex_match_["Woods::Console::CredentialIndex#match?"]
  Woods__Console__CredentialIndex_redact["Woods::Console::CredentialIndex#redact"]
  Woods__Console__CredentialScanner["Woods::Console::CredentialScanner"]
  Woods__Console__CredentialScanner_patterns["Woods::Console::CredentialScanner.patterns"]
  PATTERNS["PATTERNS"]
  Woods__Console__CredentialScanner_patterns -->|method_call| PATTERNS
  Woods__Console__CredentialScanner_replace_index_["Woods::Console::CredentialScanner#replace_index!"]
  Woods__Console__CredentialScanner_initialize["Woods::Console::CredentialScanner#initialize"]
  Woods__Console__CredentialScanner_initialize -->|method_call| Array
  Woods__Console__CredentialScanner_initialize -->|method_call| PATTERNS
  Woods__Console__CredentialScanner_scan["Woods::Console::CredentialScanner#scan"]
  Woods__Console__CredentialScanner_walk["Woods::Console::CredentialScanner#walk"]
  Woods__Console__CredentialScanner_walk_hash["Woods::Console::CredentialScanner#walk_hash"]
  Woods__Console__CredentialScanner_scan_string["Woods::Console::CredentialScanner#scan_string"]
  Woods__Console__CredentialScanner_scan_encoded_forms["Woods::Console::CredentialScanner#scan_encoded_forms"]
  Woods__Console__CredentialScanner_scan_url_encoded["Woods::Console::CredentialScanner#scan_url_encoded"]
  Woods__Console__CredentialScanner_scan_base64["Woods::Console::CredentialScanner#scan_base64"]
  Woods__Console__CredentialScanner_first_matching_pattern["Woods::Console::CredentialScanner#first_matching_pattern"]
  Woods__Console__CredentialScanner_safely_unescape["Woods::Console::CredentialScanner#safely_unescape"]
  CGI["CGI"]
  Woods__Console__CredentialScanner_safely_unescape -->|method_call| CGI
  Woods__Console__CredentialScanner_safely_base64_decode["Woods::Console::CredentialScanner#safely_base64_decode"]
  Base64["Base64"]
  Woods__Console__CredentialScanner_safely_base64_decode -->|method_call| Base64
  Woods__Console__CredentialScanner_mostly_printable_["Woods::Console::CredentialScanner#mostly_printable?"]
  Woods__Console__CredentialScanner_redact_indexed_secrets["Woods::Console::CredentialScanner#redact_indexed_secrets"]
  Woods__Console__DispatchPipeline["Woods::Console::DispatchPipeline"]
  Woods__Console__DispatchPipeline_initialize["Woods::Console::DispatchPipeline#initialize"]
  Woods__Console__DispatchPipeline_call["Woods::Console::DispatchPipeline#call"]
  InputContract["InputContract"]
  Woods__Console__DispatchPipeline_call -->|method_call| InputContract
  Woods__Console__DispatchPipeline_send_to_bridge["Woods::Console::DispatchPipeline#send_to_bridge"]
  Woods__Console__DispatchPipeline_send_to_bridge -->|method_call| JSON
  Woods__Console__DispatchPipeline_error_from_response["Woods::Console::DispatchPipeline#error_from_response"]
  Woods__Console__DispatchPipeline_scan_for_credentials["Woods::Console::DispatchPipeline#scan_for_credentials"]
  Woods__Console__DispatchPipeline_scan_early_error["Woods::Console::DispatchPipeline#scan_early_error"]
  Woods__Console__DispatchPipeline_log_credential_hits["Woods::Console::DispatchPipeline#log_credential_hits"]
  Woods__Console__DispatchPipeline_log_table_gate_rejection["Woods::Console::DispatchPipeline#log_table_gate_rejection"]
  Woods__Console__DispatchPipeline_success_response["Woods::Console::DispatchPipeline#success_response"]
  MCP__Tool__Response["MCP::Tool::Response"]
  Woods__Console__DispatchPipeline_success_response -->|method_call| MCP__Tool__Response
  Woods__Console__DispatchPipeline_error_response["Woods::Console::DispatchPipeline#error_response"]
  Woods__Console__DispatchPipeline_error_response -->|method_call| MCP__Tool__Response
  Woods__Console__EmbeddedExecutor["Woods::Console::EmbeddedExecutor"]
  Woods__Console__EmbeddedExecutor_initialize["Woods::Console::EmbeddedExecutor#initialize"]
  Woods__Console__EmbeddedExecutor_send_request["Woods::Console::EmbeddedExecutor#send_request"]
  Process["Process"]
  Woods__Console__EmbeddedExecutor_send_request -->|method_call| Process
  Process_clock_gettime["Process.clock_gettime"]
  Woods__Console__EmbeddedExecutor_send_request -->|method_call| Process_clock_gettime
  Woods__Console__EmbeddedExecutor_sanitize_execution_error["Woods::Console::EmbeddedExecutor#sanitize_execution_error"]
  Woods__Console__EmbeddedExecutor_log_execution_error["Woods::Console::EmbeddedExecutor#log_execution_error"]
  Woods__Console__EmbeddedExecutor_log_execution_error -->|method_call| Rails
  Rails_logger["Rails.logger"]
  Woods__Console__EmbeddedExecutor_log_execution_error -->|method_call| Rails_logger
  Woods__Console__EmbeddedExecutor_refusal_for["Woods::Console::EmbeddedExecutor#refusal_for"]
  TIER1_TOOLS["TIER1_TOOLS"]
  Woods__Console__EmbeddedExecutor_refusal_for -->|method_call| TIER1_TOOLS
  EMBEDDED_READ_TOOLS["EMBEDDED_READ_TOOLS"]
  Woods__Console__EmbeddedExecutor_refusal_for -->|method_call| EMBEDDED_READ_TOOLS
  Woods__Console__EmbeddedExecutor_unsupported_message["Woods::Console::EmbeddedExecutor#unsupported_message"]
  Woods__Console__EmbeddedExecutor_unsupported_message -->|method_call| EMBEDDED_READ_TOOLS
  Woods__Console__EmbeddedExecutor_eval_disabled_message["Woods::Console::EmbeddedExecutor#eval_disabled_message"]
  Woods__Console__EmbeddedExecutor_handle_eval["Woods::Console::EmbeddedExecutor#handle_eval"]
  Woods__Console__EmbeddedExecutor_execute_and_audit["Woods::Console::EmbeddedExecutor#execute_and_audit"]
  Woods__Console__EmbeddedExecutor_eval_timeout_from["Woods::Console::EmbeddedExecutor#eval_timeout_from"]
  Woods__Console__EmbeddedExecutor_guard_check_["Woods::Console::EmbeddedExecutor#guard_check!"]
  Woods__Console__EmbeddedExecutor_confirm_["Woods::Console::EmbeddedExecutor#confirm!"]
  Woods__Console__EmbeddedExecutor_run_eval_with_timeout["Woods::Console::EmbeddedExecutor#run_eval_with_timeout"]
  Timeout["Timeout"]
  Woods__Console__EmbeddedExecutor_run_eval_with_timeout -->|method_call| Timeout
  Woods__Console__EmbeddedExecutor_eval_in_sandbox["Woods::Console::EmbeddedExecutor#eval_in_sandbox"]
  Object_new["Object.new"]
  Woods__Console__EmbeddedExecutor_eval_in_sandbox -->|method_call| Object_new
  Object["Object"]
  Woods__Console__EmbeddedExecutor_eval_in_sandbox -->|method_call| Object
  Woods__Console__EmbeddedExecutor_audit["Woods::Console::EmbeddedExecutor#audit"]
  Woods__Console__EmbeddedExecutor_audit_summary["Woods::Console::EmbeddedExecutor#audit_summary"]
  PRIMITIVE_AUDIT_TYPES["PRIMITIVE_AUDIT_TYPES"]
  Woods__Console__EmbeddedExecutor_audit_summary -->|method_call| PRIMITIVE_AUDIT_TYPES
  Woods__Console__EmbeddedExecutor_truncate["Woods::Console::EmbeddedExecutor#truncate"]
  Woods__Console__EmbeddedExecutor_dispatch["Woods::Console::EmbeddedExecutor#dispatch"]
  Woods__Console__EmbeddedExecutor_normalize_params_["Woods::Console::EmbeddedExecutor#normalize_params!"]
  Server__TOOL_SPECS["Server::TOOL_SPECS"]
  Woods__Console__EmbeddedExecutor_normalize_params_ -->|method_call| Server__TOOL_SPECS
  Server__EXECUTABLE_MODES_values["Server::EXECUTABLE_MODES.values"]
  Woods__Console__EmbeddedExecutor_normalize_params_ -->|method_call| Server__EXECUTABLE_MODES_values
  Woods__Console__EmbeddedExecutor_normalize_params_ -->|method_call| InputContract
  Woods__Console__EmbeddedExecutor_validate_model_["Woods::Console::EmbeddedExecutor#validate_model!"]
  Woods__Console__EmbeddedExecutor_gate_model_["Woods::Console::EmbeddedExecutor#gate_model!"]
  Woods__Console__EmbeddedExecutor_gate_sql_["Woods::Console::EmbeddedExecutor#gate_sql!"]
  Woods__Console__EmbeddedExecutor_gate_joins_["Woods::Console::EmbeddedExecutor#gate_joins!"]
  Woods__Console__EmbeddedExecutor_resolve_model["Woods::Console::EmbeddedExecutor#resolve_model"]
  Woods__Console__EmbeddedExecutor_handle_count["Woods::Console::EmbeddedExecutor#handle_count"]
  Woods__Console__EmbeddedExecutor_handle_sample["Woods::Console::EmbeddedExecutor#handle_sample"]
  Woods__Console__EmbeddedExecutor_handle_find["Woods::Console::EmbeddedExecutor#handle_find"]
  Woods__Console__EmbeddedExecutor_validate_find_locator_["Woods::Console::EmbeddedExecutor#validate_find_locator!"]
  Woods__Console__EmbeddedExecutor_handle_pluck["Woods::Console::EmbeddedExecutor#handle_pluck"]
  Woods__Console__EmbeddedExecutor_handle_aggregate["Woods::Console::EmbeddedExecutor#handle_aggregate"]
  Server__AGGREGATE_FUNCTIONS["Server::AGGREGATE_FUNCTIONS"]
  Woods__Console__EmbeddedExecutor_handle_aggregate -->|method_call| Server__AGGREGATE_FUNCTIONS
  Woods__Console__EmbeddedExecutor_handle_association_count["Woods::Console::EmbeddedExecutor#handle_association_count"]
  Woods__Console__EmbeddedExecutor_gate_association_sql_["Woods::Console::EmbeddedExecutor#gate_association_sql!"]
  Woods__Console__EmbeddedExecutor_validate_scope_columns_["Woods::Console::EmbeddedExecutor#validate_scope_columns!"]
  Woods__Console__EmbeddedExecutor_scope_key_column["Woods::Console::EmbeddedExecutor#scope_key_column"]
  ScopePredicateParser__SUFFIX_PATTERN["ScopePredicateParser::SUFFIX_PATTERN"]
  Woods__Console__EmbeddedExecutor_scope_key_column -->|method_call| ScopePredicateParser__SUFFIX_PATTERN
  Woods__Console__EmbeddedExecutor_refuse_redacted_column_["Woods::Console::EmbeddedExecutor#refuse_redacted_column!"]
  Woods__Console__EmbeddedExecutor_refuse_redacted_scope_keys_["Woods::Console::EmbeddedExecutor#refuse_redacted_scope_keys!"]
  Woods__Console__EmbeddedExecutor_gate_association_["Woods::Console::EmbeddedExecutor#gate_association!"]
  Woods__Console__EmbeddedExecutor_handle_schema["Woods::Console::EmbeddedExecutor#handle_schema"]
  Woods__Console__EmbeddedExecutor_handle_recent["Woods::Console::EmbeddedExecutor#handle_recent"]
  Woods__Console__EmbeddedExecutor_handle_status["Woods::Console::EmbeddedExecutor#handle_status"]
  Woods__Console__EmbeddedExecutor_handle_sql["Woods::Console::EmbeddedExecutor#handle_sql"]
  SqlValidator_new["SqlValidator.new"]
  Woods__Console__EmbeddedExecutor_handle_sql -->|method_call| SqlValidator_new
  SqlValidator["SqlValidator"]
  Woods__Console__EmbeddedExecutor_handle_sql -->|method_call| SqlValidator
  Woods__Console__EmbeddedExecutor_explain_statement_["Woods::Console::EmbeddedExecutor#explain_statement?"]
  Woods__Console__EmbeddedExecutor_handle_query["Woods::Console::EmbeddedExecutor#handle_query"]
  Woods__Console__EmbeddedExecutor_build_query_relation["Woods::Console::EmbeddedExecutor#build_query_relation"]
  Woods__Console__EmbeddedExecutor_apply_query_clauses["Woods::Console::EmbeddedExecutor#apply_query_clauses"]
  Woods__Console__EmbeddedExecutor_validated_select["Woods::Console::EmbeddedExecutor#validated_select"]
  Woods__Console__EmbeddedExecutor_validated_select -->|method_call| Array
  Woods__Console__EmbeddedExecutor_validate_select_expression_["Woods::Console::EmbeddedExecutor#validate_select_expression!"]
  Server__SELECT_EXPRESSION_REGEXP["Server::SELECT_EXPRESSION_REGEXP"]
  Woods__Console__EmbeddedExecutor_validate_select_expression_ -->|method_call| Server__SELECT_EXPRESSION_REGEXP
  Woods__Console__EmbeddedExecutor_validated_columns["Woods::Console::EmbeddedExecutor#validated_columns"]
  Array_flat_map["Array.flat_map"]
  Woods__Console__EmbeddedExecutor_validated_columns -->|method_call| Array_flat_map
  Woods__Console__EmbeddedExecutor_validated_having["Woods::Console::EmbeddedExecutor#validated_having"]
  Woods__Console__EmbeddedExecutor_validated_having_array_["Woods::Console::EmbeddedExecutor#validated_having_array!"]
  Server__HAVING_TEMPLATE_REGEXP["Server::HAVING_TEMPLATE_REGEXP"]
  Woods__Console__EmbeddedExecutor_validated_having_array_ -->|method_call| Server__HAVING_TEMPLATE_REGEXP
  Woods__Console__EmbeddedExecutor_validate_having_bind_["Woods::Console::EmbeddedExecutor#validate_having_bind!"]
  Woods__Console__EmbeddedExecutor_apply_query_scope["Woods::Console::EmbeddedExecutor#apply_query_scope"]
  Server__QUERY_SCOPE_TEMPLATE_REGEXP["Server::QUERY_SCOPE_TEMPLATE_REGEXP"]
  Woods__Console__EmbeddedExecutor_apply_query_scope -->|method_call| Server__QUERY_SCOPE_TEMPLATE_REGEXP
  Woods__Console__EmbeddedExecutor_validated_order["Woods::Console::EmbeddedExecutor#validated_order"]
  Woods__Console__EmbeddedExecutor_validate_column_reference_["Woods::Console::EmbeddedExecutor#validate_column_reference!"]
  Woods__Console__EmbeddedExecutor_safe_identifier_["Woods::Console::EmbeddedExecutor#safe_identifier?"]
  Woods__Console__EmbeddedExecutor_validate_joins_["Woods::Console::EmbeddedExecutor#validate_joins!"]
  Woods__Console__EmbeddedExecutor_apply_scope["Woods::Console::EmbeddedExecutor#apply_scope"]
  ScopePredicateParser["ScopePredicateParser"]
  Woods__Console__EmbeddedExecutor_apply_scope -->|method_call| ScopePredicateParser
  Woods__Console__EmbeddedExecutor_validate_scope_array_["Woods::Console::EmbeddedExecutor#validate_scope_array!"]
  SqlNoiseStripper["SqlNoiseStripper"]
  Woods__Console__EmbeddedExecutor_validate_scope_array_ -->|method_call| SqlNoiseStripper
  SCOPE_TEMPLATE_FORBIDDEN["SCOPE_TEMPLATE_FORBIDDEN"]
  Woods__Console__EmbeddedExecutor_validate_scope_array_ -->|method_call| SCOPE_TEMPLATE_FORBIDDEN
  Woods__Console__EmbeddedExecutor_validate_select_columns_["Woods::Console::EmbeddedExecutor#validate_select_columns!"]
  Woods__Console__EmbeddedExecutor_apply_columns["Woods::Console::EmbeddedExecutor#apply_columns"]
  Woods__Console__EmbeddedExecutor_serialize_record["Woods::Console::EmbeddedExecutor#serialize_record"]
  Woods__Console__EmbeddedExecutor_serialize_records["Woods::Console::EmbeddedExecutor#serialize_records"]
  Woods__Console__EmbeddedExecutor_random_function["Woods::Console::EmbeddedExecutor#random_function"]
  Arel["Arel"]
  Woods__Console__EmbeddedExecutor_random_function -->|method_call| Arel
  Woods__Console__EmbeddedExecutor_active_connection["Woods::Console::EmbeddedExecutor#active_connection"]
  Thread_current["Thread.current"]
  Woods__Console__EmbeddedExecutor_active_connection -->|method_call| Thread_current
  Thread["Thread"]
  Woods__Console__EmbeddedExecutor_active_connection -->|method_call| Thread
  ActiveRecord__Base["ActiveRecord::Base"]
  Woods__Console__EmbeddedExecutor_active_connection -->|method_call| ActiveRecord__Base
  Woods__Console__EmbeddedExecutor_deep_stringify_keys["Woods::Console::EmbeddedExecutor#deep_stringify_keys"]
  Woods__Console__ForbiddenExpressionError["Woods::Console::ForbiddenExpressionError"]
  Woods__Console__ForbiddenExpressionError -->|inheritance| Woods__Error
  Woods__Console__EvalGuard["Woods::Console::EvalGuard"]
  Woods__Console__EvalGuard_initialize["Woods::Console::EvalGuard#initialize"]
  Woods__Console__EvalGuard_check_["Woods::Console::EvalGuard#check!"]
  Woods__Console__EvalGuard_parse_or_refuse["Woods::Console::EvalGuard#parse_or_refuse"]
  Woods__Console__EvalGuard_scan_send_nodes["Woods::Console::EvalGuard#scan_send_nodes"]
  Woods__Console__EvalGuard_scan_const_nodes["Woods::Console::EvalGuard#scan_const_nodes"]
  DENIED_CONSTANTS["DENIED_CONSTANTS"]
  Woods__Console__EvalGuard_scan_const_nodes -->|method_call| DENIED_CONSTANTS
  Woods__Console__EvalGuard_scan_assignment_nodes["Woods::Console::EvalGuard#scan_assignment_nodes"]
  Woods__Console__EvalGuard_refuse_class_or_global_var_assignment_["Woods::Console::EvalGuard#refuse_class_or_global_var_assignment!"]
  CLASS_OR_GLOBAL_VAR_ASSIGNMENT["CLASS_OR_GLOBAL_VAR_ASSIGNMENT"]
  Woods__Console__EvalGuard_refuse_class_or_global_var_assignment_ -->|method_call| CLASS_OR_GLOBAL_VAR_ASSIGNMENT
  Woods__Console__EvalGuard_refuse_reflection_["Woods::Console::EvalGuard#refuse_reflection!"]
  DENIED_REFLECTION["DENIED_REFLECTION"]
  Woods__Console__EvalGuard_refuse_reflection_ -->|method_call| DENIED_REFLECTION
  Woods__Console__EvalGuard_refuse_denied_constant_receiver_["Woods::Console::EvalGuard#refuse_denied_constant_receiver!"]
  Woods__Console__EvalGuard_refuse_denied_constant_receiver_ -->|method_call| DENIED_CONSTANTS
  Woods__Console__EvalGuard_refuse_denied_constant_in_args_["Woods::Console::EvalGuard#refuse_denied_constant_in_args!"]
  Woods__Console__EvalGuard_refuse_denied_constant_in_args_ -->|method_call| DENIED_CONSTANTS
  Woods__Console__EvalGuard_refuse_denied_constant_in_args_ -->|method_call| Regexp
  Woods__Console__EvalGuard_refuse_denied_constant_in_args_ -->|method_call| Array
  Woods__Console__EvalGuard_refuse_denied_call_chain_["Woods::Console::EvalGuard#refuse_denied_call_chain!"]
  DENIED_CALL_CHAINS["DENIED_CALL_CHAINS"]
  Woods__Console__EvalGuard_refuse_denied_call_chain_ -->|method_call| DENIED_CALL_CHAINS
  Woods__Console__EvalGuard_refuse_credential_file_read_["Woods::Console::EvalGuard#refuse_credential_file_read!"]
  CREDENTIAL_FILE_READERS["CREDENTIAL_FILE_READERS"]
  Woods__Console__EvalGuard_refuse_credential_file_read_ -->|method_call| CREDENTIAL_FILE_READERS
  CREDENTIAL_FILE_READERS_fetch["CREDENTIAL_FILE_READERS.fetch"]
  Woods__Console__EvalGuard_refuse_credential_file_read_ -->|method_call| CREDENTIAL_FILE_READERS_fetch
  Woods__Console__EvalGuard_refuse_credential_file_read_ -->|method_call| Array
  Woods__Console__EvalGuard_qualified_call["Woods::Console::EvalGuard#qualified_call"]
  Woods__Console__EvalGuard_credential_path_["Woods::Console::EvalGuard#credential_path?"]
  CREDENTIAL_PATH_HINTS["CREDENTIAL_PATH_HINTS"]
  Woods__Console__EvalGuard_credential_path_ -->|method_call| CREDENTIAL_PATH_HINTS
  Woods__Console__InputContract["Woods::Console::InputContract"]
  Woods__Console__InputContract__ValidationError["Woods::Console::InputContract::ValidationError"]
  Woods__Console__InputContract__ValidationError -->|inheritance| StandardError
  Woods__Console__InputContract_normalize_["Woods::Console::InputContract#normalize!"]
  Woods__Console__InputContract_reject_string_typed_integers_["Woods::Console::InputContract#reject_string_typed_integers!"]
  Woods__Console__InputContract_argument_key["Woods::Console::InputContract#argument_key"]
  Woods__Console__InputContract_parse_integer["Woods::Console::InputContract#parse_integer"]
  DECIMAL_INTEGER["DECIMAL_INTEGER"]
  Woods__Console__InputContract_parse_integer -->|method_call| DECIMAL_INTEGER
  Woods__Console__InputContract_enforce_bounds_["Woods::Console::InputContract#enforce_bounds!"]
  Woods__Console__ValidationError["Woods::Console::ValidationError"]
  Woods__Console__ValidationError -->|inheritance| Woods__Error
  Woods__Console__ModelValidator["Woods::Console::ModelValidator"]
  Woods__Console__ModelValidator_initialize["Woods::Console::ModelValidator#initialize"]
  Woods__Console__ModelValidator_validate_model_["Woods::Console::ModelValidator#validate_model!"]
  Woods__Console__ModelValidator_validate_column_["Woods::Console::ModelValidator#validate_column!"]
  Woods__Console__ModelValidator_validate_columns_["Woods::Console::ModelValidator#validate_columns!"]
  Woods__Console__ModelValidator_validate_table_column_["Woods::Console::ModelValidator#validate_table_column!"]
  Woods__Console__ModelValidator_model_names["Woods::Console::ModelValidator#model_names"]
  Woods__Console__ModelValidator_columns_for["Woods::Console::ModelValidator#columns_for"]
  Woods__Console__RackMiddleware["Woods::Console::RackMiddleware"]
  Woods__Console__RackMiddleware_initialize["Woods::Console::RackMiddleware#initialize"]
  Woods__Console__RackMiddleware_initialize -->|method_call| Mutex
  Woods__Console__RackMiddleware_call["Woods::Console::RackMiddleware#call"]
  Woods__Console__RackMiddleware_enabled_["Woods::Console::RackMiddleware#enabled?"]
  Woods_configuration["Woods.configuration"]
  Woods__Console__RackMiddleware_enabled_ -->|method_call| Woods_configuration
  Woods__Console__RackMiddleware_enabled_ -->|method_call| Woods
  Woods__Console__RackMiddleware_ensure_transport["Woods::Console::RackMiddleware#ensure_transport"]
  Rails_application["Rails.application"]
  Woods__Console__RackMiddleware_ensure_transport -->|method_call| Rails_application
  Woods__Console__RackMiddleware_ensure_transport -->|method_call| Rails
  MCP__Server__Transports__StreamableHTTPTransport["MCP::Server::Transports::StreamableHTTPTransport"]
  Woods__Console__RackMiddleware_ensure_transport -->|method_call| MCP__Server__Transports__StreamableHTTPTransport
  Woods__Console__RackMiddleware_check_blocked_tables_config_["Woods::Console::RackMiddleware#check_blocked_tables_config!"]
  Woods_configuration_console_blocked_tables["Woods.configuration.console_blocked_tables"]
  Woods__Console__RackMiddleware_check_blocked_tables_config_ -->|method_call| Woods_configuration_console_blocked_tables
  Woods__Console__RackMiddleware_check_blocked_tables_config_ -->|method_call| Woods_configuration
  Woods__Console__RackMiddleware_check_blocked_tables_config_ -->|method_call| Woods
  Rails_env["Rails.env"]
  Woods__Console__RackMiddleware_check_blocked_tables_config_ -->|method_call| Rails_env
  Woods__Console__RackMiddleware_check_blocked_tables_config_ -->|method_call| Rails
  Woods__Console__RackMiddleware_build_embedded_server["Woods::Console::RackMiddleware#build_embedded_server"]
  Woods__Console__RackMiddleware_build_embedded_server -->|method_call| Woods
  Server["Server"]
  Woods__Console__RackMiddleware_build_embedded_server -->|method_call| Server
  Woods__Console__RackMiddleware_build_model_introspection["Woods::Console::RackMiddleware#build_model_introspection"]
  ActiveRecord__Base_descendants["ActiveRecord::Base.descendants"]
  Woods__Console__RackMiddleware_build_model_introspection -->|method_call| ActiveRecord__Base_descendants
  Woods__Console__RackMiddleware_reflections_for["Woods::Console::RackMiddleware#reflections_for"]
  Woods__Console__RackMiddleware_resolve_deferred["Woods::Console::RackMiddleware#resolve_deferred"]
  Woods__Console__RackMiddleware_structured_logger["Woods::Console::RackMiddleware#structured_logger"]
  Woods__Observability__StructuredLogger["Woods::Observability::StructuredLogger"]
  Woods__Console__RackMiddleware_structured_logger -->|method_call| Woods__Observability__StructuredLogger
  Woods__Console__Redactor["Woods::Console::Redactor"]
  Woods__Console__Redactor_apply["Woods::Console::Redactor#apply"]
  Woods__Console__Redactor_redact_hash["Woods::Console::Redactor#redact_hash"]
  Woods__Console__Redactor_redact_envelope_value["Woods::Console::Redactor#redact_envelope_value"]
  Woods__Console__Redactor_redact_hash_array["Woods::Console::Redactor#redact_hash_array"]
  Woods__Console__Redactor_redact_hash_array -->|method_call| Array
  Woods__Console__Redactor_redact_association_map["Woods::Console::Redactor#redact_association_map"]
  Woods__Console__Redactor_positional_plan["Woods::Console::Redactor#positional_plan"]
  Woods__Console__Redactor_positional_mask["Woods::Console::Redactor#positional_mask"]
  Woods__Console__Redactor_positional_kv_rules["Woods::Console::Redactor#positional_kv_rules"]
  Woods__Console__Redactor_redact_positional["Woods::Console::Redactor#redact_positional"]
  Woods__Console__Redactor_redact_row["Woods::Console::Redactor#redact_row"]
  Woods__Console__Redactor_apply_mask["Woods::Console::Redactor#apply_mask"]
  Woods__Console__Redactor_redact_scalar["Woods::Console::Redactor#redact_scalar"]
  Woods__Console__ResponseContext["Woods::Console::ResponseContext"]
  Woods__Console__NullResponseContext["Woods::Console::NullResponseContext"]
  Singleton["Singleton"]
  Woods__Console__NullResponseContext -->|include| Singleton
  Woods__Console__ResponseContext_build["Woods::Console::ResponseContext.build"]
  NullResponseContext["NullResponseContext"]
  Woods__Console__ResponseContext_build -->|method_call| NullResponseContext
  Woods__Console__ResponseContext_initialize["Woods::Console::ResponseContext#initialize"]
  Woods__Console__ResponseContext_present_["Woods::Console::ResponseContext#present?"]
  Woods__Console__ResponseContext_enforce_["Woods::Console::ResponseContext#enforce!"]
  Woods__Console__ResponseContext_redact["Woods::Console::ResponseContext#redact"]
  Redactor["Redactor"]
  Woods__Console__ResponseContext_redact -->|method_call| Redactor
  Woods__Console__ResponseContext_scan["Woods::Console::ResponseContext#scan"]
  Woods__Console__NullResponseContext_present_["Woods::Console::NullResponseContext#present?"]
  Woods__Console__NullResponseContext_safe_ctx["Woods::Console::NullResponseContext#safe_ctx"]
  Woods__Console__NullResponseContext_table_gate["Woods::Console::NullResponseContext#table_gate"]
  Woods__Console__NullResponseContext_credential_scanner["Woods::Console::NullResponseContext#credential_scanner"]
  Woods__Console__NullResponseContext_enforce_["Woods::Console::NullResponseContext#enforce!"]
  Woods__Console__NullResponseContext_redact["Woods::Console::NullResponseContext#redact"]
  Woods__Console__NullResponseContext_scan["Woods::Console::NullResponseContext#scan"]
  ActiveRecord["ActiveRecord"]
  ActiveRecord__Rollback["ActiveRecord::Rollback"]
  ActiveRecord__Rollback -->|inheritance| StandardError
  Woods__Console__SafeContext["Woods::Console::SafeContext"]
  Woods__Console__SafeContext_initialize["Woods::Console::SafeContext#initialize"]
  SingleConnectionPool["SingleConnectionPool"]
  Woods__Console__SafeContext_initialize -->|method_call| SingleConnectionPool
  Woods__Console__SafeContext_execute["Woods::Console::SafeContext#execute"]
  Woods__Console__SafeContext_redact["Woods::Console::SafeContext#redact"]
  Woods__Console__SafeContext_run_with_timeout["Woods::Console::SafeContext#run_with_timeout"]
  Woods__Console__SafeContext_run_with_timeout -->|method_call| Thread_current
  Woods__Console__SafeContext_run_with_timeout -->|method_call| Thread
  Woods__Console__SafeContext_normalize_key_value_patterns["Woods::Console::SafeContext#normalize_key_value_patterns"]
  Woods__Console__SafeContext_normalize_key_value_patterns -->|method_call| Array
  Woods__Console__SafeContext_normalize_pattern["Woods::Console::SafeContext#normalize_pattern"]
  Woods__Console__SafeContext_normalize_pattern -->|method_call| Array
  Woods__Console__SafeContext_fetch_pattern_string["Woods::Console::SafeContext#fetch_pattern_string"]
  Woods__Console__SafeContext_apply_key_value_redaction["Woods::Console::SafeContext#apply_key_value_redaction"]
  Woods__Console__SafeContext_set_timeout["Woods::Console::SafeContext#set_timeout"]
  Woods__Console__SafeContext_set_mysql_timeout["Woods::Console::SafeContext#set_mysql_timeout"]
  Woods__Console__SafeContext_warn_timeout_unsupported["Woods::Console::SafeContext#warn_timeout_unsupported"]
  Woods__Console__SafeContext_warn_timeout_unsupported -->|method_call| Rails
  Woods__Console__SafeContext_warn_timeout_unsupported -->|method_call| Rails_logger
  Woods__Console__ScopePredicateParser["Woods::Console::ScopePredicateParser"]
  Woods__Console__ScopePredicateParser_initialize["Woods::Console::ScopePredicateParser#initialize"]
  Woods__Console__ScopePredicateParser_parse["Woods::Console::ScopePredicateParser#parse"]
  SUFFIX_PATTERN["SUFFIX_PATTERN"]
  Woods__Console__ScopePredicateParser_parse -->|method_call| SUFFIX_PATTERN
  Woods__Console__ScopePredicateParser_validate_suffix_value_type_["Woods::Console::ScopePredicateParser#validate_suffix_value_type!"]
  Woods__Console__ScopePredicateParser_build_node["Woods::Console::ScopePredicateParser#build_node"]
  Woods__Console__ScopePredicateParser_arel_table["Woods::Console::ScopePredicateParser#arel_table"]
  Woods__ConfigurationError["Woods::ConfigurationError"]
  Woods__ConfigurationError -->|inheritance| Error
  Woods__Console__Server["Woods::Console::Server"]
  Woods__Console__SqlNoiseStripper["Woods::Console::SqlNoiseStripper"]
  Woods__Console__SqlNoiseStripper_strip_comments["Woods::Console::SqlNoiseStripper.strip_comments"]
  Woods__Console__SqlNoiseStripper_strip_literals["Woods::Console::SqlNoiseStripper.strip_literals"]
  SUPPORTED_DIALECTS["SUPPORTED_DIALECTS"]
  Woods__Console__SqlNoiseStripper_strip_literals -->|method_call| SUPPORTED_DIALECTS
  Woods__Console__SqlNoiseStripper_strip_noise["Woods::Console::SqlNoiseStripper.strip_noise"]
  Woods__Console__SqlNoiseStripper_strip_noise -->|method_call| SUPPORTED_DIALECTS
  Woods__Console__SqlNoiseStripper_dollar_tag_at["Woods::Console::SqlNoiseStripper.dollar_tag_at"]
  DOLLAR_TAG["DOLLAR_TAG"]
  Woods__Console__SqlNoiseStripper_dollar_tag_at -->|method_call| DOLLAR_TAG
  Woods__Console__SqlNoiseStripper_preceded_by_word_char_["Woods::Console::SqlNoiseStripper.preceded_by_word_char?"]
  Woods__Console__SqlNoiseStripper_single_quote_end["Woods::Console::SqlNoiseStripper.single_quote_end"]
  Woods__Console__SqlTableScanner["Woods::Console::SqlTableScanner"]
  Woods__Console__SqlTableScanner_identifiers_in["Woods::Console::SqlTableScanner.identifiers_in"]
  Woods__Console__SqlTableScanner_strip_noise["Woods::Console::SqlTableScanner.strip_noise"]
  Woods__Console__SqlTableScanner_strip_noise -->|method_call| SqlNoiseStripper
  Woods__Console__SqlTableScanner_collect_join_identifiers["Woods::Console::SqlTableScanner.collect_join_identifiers"]
  Woods__Console__SqlTableScanner_collect_join_identifiers -->|method_call| Regexp
  Woods__Console__SqlTableScanner_collect_from_identifiers["Woods::Console::SqlTableScanner.collect_from_identifiers"]
  Regexp_last_match["Regexp.last_match"]
  Woods__Console__SqlTableScanner_collect_from_identifiers -->|method_call| Regexp_last_match
  Woods__Console__SqlTableScanner_collect_from_identifiers -->|method_call| Regexp
  Woods__Console__SqlTableScanner_collect_table_statement_identifiers["Woods::Console::SqlTableScanner.collect_table_statement_identifiers"]
  Woods__Console__SqlTableScanner_split_top_level_commas["Woods::Console::SqlTableScanner.split_top_level_commas"]
  Woods__Console__SqlTableScanner_lead_identifier["Woods::Console::SqlTableScanner.lead_identifier"]
  LEAD_IDENT["LEAD_IDENT"]
  Woods__Console__SqlTableScanner_lead_identifier -->|method_call| LEAD_IDENT
  Woods__Console__SqlTableScanner_qualified_identifier["Woods::Console::SqlTableScanner.qualified_identifier"]
  Woods__Console__SqlValidationError["Woods::Console::SqlValidationError"]
  Woods__Console__SqlValidationError -->|inheritance| Woods__Error
  Woods__Console__SqlValidator["Woods::Console::SqlValidator"]
  Woods__Console__SqlValidator_validate_["Woods::Console::SqlValidator#validate!"]
  Woods__Console__SqlValidator_valid_["Woods::Console::SqlValidator#valid?"]
  Woods__Console__SqlValidator_contains_multiple_statements_["Woods::Console::SqlValidator#contains_multiple_statements?"]
  Woods__Console__SqlValidator_contains_multiple_statements_ -->|method_call| SqlNoiseStripper
  Woods__Console__SqlValidator_check_forbidden_keywords_["Woods::Console::SqlValidator#check_forbidden_keywords!"]
  FORBIDDEN_PREFIX_REGEXES["FORBIDDEN_PREFIX_REGEXES"]
  Woods__Console__SqlValidator_check_forbidden_keywords_ -->|method_call| FORBIDDEN_PREFIX_REGEXES
  Woods__Console__SqlValidator_check_body_forbidden_keywords_["Woods::Console::SqlValidator#check_body_forbidden_keywords!"]
  Woods__Console__SqlValidator_check_body_forbidden_keywords_ -->|method_call| SqlNoiseStripper
  BODY_FORBIDDEN_REGEXES["BODY_FORBIDDEN_REGEXES"]
  Woods__Console__SqlValidator_check_body_forbidden_keywords_ -->|method_call| BODY_FORBIDDEN_REGEXES
  Woods__Console__SqlValidator_check_writable_ctes_["Woods::Console::SqlValidator#check_writable_ctes!"]
  Woods__Console__SqlValidator_check_writable_ctes_ -->|method_call| SqlNoiseStripper
  Woods__Console__SqlValidator_check_dangerous_functions_["Woods::Console::SqlValidator#check_dangerous_functions!"]
  Woods__Console__SqlValidator_check_dangerous_functions_ -->|method_call| SqlNoiseStripper
  DANGEROUS_FUNCTION_REGEXES["DANGEROUS_FUNCTION_REGEXES"]
  Woods__Console__SqlValidator_check_dangerous_functions_ -->|method_call| DANGEROUS_FUNCTION_REGEXES
  Woods__Console__SqlValidator_check_function_allowlist_["Woods::Console::SqlValidator#check_function_allowlist!"]
  Woods__Console__SqlValidator_check_function_allowlist_ -->|method_call| SqlNoiseStripper
  Woods__Console__SqlValidator_check_function_allowlist_ -->|method_call| Regexp
  FUNCTION_SCAN_EXCLUDED_KEYWORDS["FUNCTION_SCAN_EXCLUDED_KEYWORDS"]
  Woods__Console__SqlValidator_check_function_allowlist_ -->|method_call| FUNCTION_SCAN_EXCLUDED_KEYWORDS
  ALLOWED_FUNCTIONS["ALLOWED_FUNCTIONS"]
  Woods__Console__SqlValidator_check_function_allowlist_ -->|method_call| ALLOWED_FUNCTIONS
  Woods__Console__SqlValidator_check_forbidden_keywords_in_body_["Woods::Console::SqlValidator#check_forbidden_keywords_in_body!"]
  Woods__Console__SqlValidator_check_forbidden_keywords_in_body_ -->|method_call| SqlNoiseStripper
  FORBIDDEN_BODY_REGEXES["FORBIDDEN_BODY_REGEXES"]
  Woods__Console__SqlValidator_check_forbidden_keywords_in_body_ -->|method_call| FORBIDDEN_BODY_REGEXES
  Woods__Console__TableGateError["Woods::Console::TableGateError"]
  Woods__Console__TableGateError -->|inheritance| Woods__Error
  Woods__Console__TableGate["Woods::Console::TableGate"]
  Woods__Console__TableGate_initialize["Woods::Console::TableGate#initialize"]
  Set["Set"]
  Woods__Console__TableGate_initialize -->|method_call| Set
  Woods__Console__TableGate_initialize -->|method_call| Array
  Woods__Console__TableGate_active_["Woods::Console::TableGate#active?"]
  Woods__Console__TableGate_check_sql_["Woods::Console::TableGate#check_sql!"]
  SqlTableScanner_identifiers_in["SqlTableScanner.identifiers_in"]
  Woods__Console__TableGate_check_sql_ -->|method_call| SqlTableScanner_identifiers_in
  Woods__Console__TableGate_check_model_["Woods::Console::TableGate#check_model!"]
  Woods__Console__TableGate_check_table_["Woods::Console::TableGate#check_table!"]
  Woods__Console__TableGate_check_joins_["Woods::Console::TableGate#check_joins!"]
  Woods__Console__TableGate_check_joins_ -->|method_call| Array
  Woods__Console__TableGate_check_association_["Woods::Console::TableGate#check_association!"]
  Woods__Console__TableGate_blocked_["Woods::Console::TableGate#blocked?"]
  Woods__Console__TableGate_strip_schema["Woods::Console::TableGate#strip_schema"]
  Woods__Console__TableGate_reject_message["Woods::Console::TableGate#reject_message"]
  Woods__Console__Tools["Woods::Console::Tools"]
  Woods__Console__Tools__Tier1["Woods::Console::Tools::Tier1"]
  Woods__Console__Tools__Tier1_console_count["Woods::Console::Tools::Tier1#console_count"]
  Woods__Console__Tools__Tier1_console_sample["Woods::Console::Tools::Tier1#console_sample"]
  Woods__Console__Tools__Tier1_console_find["Woods::Console::Tools::Tier1#console_find"]
  Woods__Console__Tools__Tier1_console_pluck["Woods::Console::Tools::Tier1#console_pluck"]
  Woods__Console__Tools__Tier1_console_aggregate["Woods::Console::Tools::Tier1#console_aggregate"]
  Woods__Console__Tools__Tier1_console_association_count["Woods::Console::Tools::Tier1#console_association_count"]
  Woods__Console__Tools__Tier1_console_schema["Woods::Console::Tools::Tier1#console_schema"]
  Woods__Console__Tools__Tier1_console_recent["Woods::Console::Tools::Tier1#console_recent"]
  Woods__Console__Tools__Tier1_console_status["Woods::Console::Tools::Tier1#console_status"]
  Woods__Console__Tools__Tier2["Woods::Console::Tools::Tier2"]
  Woods__Console__Tools__Tier2_console_diagnose_model["Woods::Console::Tools::Tier2#console_diagnose_model"]
  Woods__Console__Tools__Tier2_console_data_snapshot["Woods::Console::Tools::Tier2#console_data_snapshot"]
  Woods__Console__Tools__Tier2_console_validate_record["Woods::Console::Tools::Tier2#console_validate_record"]
  Woods__Console__Tools__Tier2_console_check_setting["Woods::Console::Tools::Tier2#console_check_setting"]
  Woods__Console__Tools__Tier2_console_update_setting["Woods::Console::Tools::Tier2#console_update_setting"]
  Woods__Console__Tools__Tier2_console_check_policy["Woods::Console::Tools::Tier2#console_check_policy"]
  Woods__Console__Tools__Tier2_console_validate_with["Woods::Console::Tools::Tier2#console_validate_with"]
  Woods__Console__Tools__Tier2_console_check_eligibility["Woods::Console::Tools::Tier2#console_check_eligibility"]
  Woods__Console__Tools__Tier2_console_decorate["Woods::Console::Tools::Tier2#console_decorate"]
  Woods__Console__Tools__Tier3["Woods::Console::Tools::Tier3"]
  Woods__Console__Tools__Tier3_console_slow_endpoints["Woods::Console::Tools::Tier3#console_slow_endpoints"]
  Woods__Console__Tools__Tier3_console_error_rates["Woods::Console::Tools::Tier3#console_error_rates"]
  Woods__Console__Tools__Tier3_console_throughput["Woods::Console::Tools::Tier3#console_throughput"]
  Woods__Console__Tools__Tier3_console_job_queues["Woods::Console::Tools::Tier3#console_job_queues"]
  Woods__Console__Tools__Tier3_console_job_failures["Woods::Console::Tools::Tier3#console_job_failures"]
  Woods__Console__Tools__Tier3_console_job_find["Woods::Console::Tools::Tier3#console_job_find"]
  Woods__Console__Tools__Tier3_console_job_schedule["Woods::Console::Tools::Tier3#console_job_schedule"]
  Woods__Console__Tools__Tier3_console_redis_info["Woods::Console::Tools::Tier3#console_redis_info"]
  Woods__Console__Tools__Tier3_console_cache_stats["Woods::Console::Tools::Tier3#console_cache_stats"]
  Woods__Console__Tools__Tier3_console_channel_status["Woods::Console::Tools::Tier3#console_channel_status"]
  Woods__Console__Tools__Tier4["Woods::Console::Tools::Tier4"]
  Woods__Console__Tools__Tier4_console_eval["Woods::Console::Tools::Tier4#console_eval"]
  Woods__Console__Tools__Tier4_console_sql["Woods::Console::Tools::Tier4#console_sql"]
  Woods__Console__Tools__Tier4_console_query["Woods::Console::Tools::Tier4#console_query"]
  Woods__Coordination["Woods::Coordination"]
  Woods__Coordination__LockHeartbeat["Woods::Coordination::LockHeartbeat"]
  Woods__Coordination__LockHeartbeat_run["Woods::Coordination::LockHeartbeat.run"]
  Woods__Coordination__LockHeartbeat_initialize["Woods::Coordination::LockHeartbeat#initialize"]
  Woods__Coordination__LockHeartbeat_start_thread["Woods::Coordination::LockHeartbeat#start_thread"]
  Woods__Coordination__LockHeartbeat_start_thread -->|method_call| Thread
  Woods__Coordination__LockHeartbeat_beat["Woods::Coordination::LockHeartbeat#beat"]
  Woods__Coordination__LockHeartbeat_now["Woods::Coordination::LockHeartbeat#now"]
  Woods__Coordination__LockHeartbeat_now -->|method_call| Process
  Woods__Coordination__LockError["Woods::Coordination::LockError"]
  Woods__Coordination__LockError -->|inheritance| Woods__Error
  Woods__Coordination__PipelineLock["Woods::Coordination::PipelineLock"]
  Woods__Coordination__PipelineLock_guard_filename["Woods::Coordination::PipelineLock.guard_filename"]
  Woods__Coordination__PipelineLock_initialize["Woods::Coordination::PipelineLock#initialize"]
  Woods__Coordination__PipelineLock_initialize -->|method_call| File
  Woods__Coordination__PipelineLock_acquire["Woods::Coordination::PipelineLock#acquire"]
  Woods__Coordination__PipelineLock_acquire -->|method_call| File
  Woods__Coordination__PipelineLock_retire_stale["Woods::Coordination::PipelineLock#retire_stale"]
  Woods__Coordination__PipelineLock_retire_stale -->|method_call| File
  Woods__Coordination__PipelineLock_release["Woods::Coordination::PipelineLock#release"]
  Woods__Coordination__PipelineLock_with_lock["Woods::Coordination::PipelineLock#with_lock"]
  Woods__Coordination__PipelineLock_locked_["Woods::Coordination::PipelineLock#locked?"]
  Woods__Coordination__PipelineLock_locked_ -->|method_call| File
  Woods__Coordination__PipelineLock_touch["Woods::Coordination::PipelineLock#touch"]
  Woods__Coordination__PipelineLock_touch -->|method_call| File
  Woods__Coordination__PipelineLock_with_path_guard["Woods::Coordination::PipelineLock#with_path_guard"]
  Woods__Coordination__PipelineLock_with_path_guard -->|method_call| FileUtils
  Woods__Coordination__PipelineLock_with_path_guard -->|method_call| File
  Woods__Coordination__PipelineLock_guard_path["Woods::Coordination::PipelineLock#guard_path"]
  Woods__Coordination__PipelineLock_guard_path -->|method_call| File
  Woods__Coordination__PipelineLock_canonical_lock_dir["Woods::Coordination::PipelineLock#canonical_lock_dir"]
  Woods__Coordination__PipelineLock_canonical_lock_dir -->|method_call| File
  Woods__Coordination__PipelineLock_retire_stale_unlocked["Woods::Coordination::PipelineLock#retire_stale_unlocked"]
  Woods__Coordination__PipelineLock_retire_stale_unlocked -->|method_call| File
  Woods__Coordination__PipelineLock_retire_stale_unlocked -->|method_call| FileUtils
  Woods__Coordination__PipelineLock_release_unlocked["Woods::Coordination::PipelineLock#release_unlocked"]
  Woods__Coordination__PipelineLock_release_unlocked -->|method_call| File
  Woods__Coordination__PipelineLock_release_unlocked -->|method_call| FileUtils
  Woods__Coordination__PipelineLock_touch_unlocked_["Woods::Coordination::PipelineLock#touch_unlocked?"]
  Woods__Coordination__PipelineLock_touch_unlocked_ -->|method_call| Time
  Woods__Coordination__PipelineLock_touch_unlocked_ -->|method_call| File
  Woods__Coordination__PipelineLock_stale_["Woods::Coordination::PipelineLock#stale?"]
  Woods__Coordination__PipelineLock_stale_ -->|method_call| File
  Woods__Coordination__PipelineLock_stale_ -->|method_call| Time_now
  Woods__Coordination__PipelineLock_stale_ -->|method_call| Time
  Woods__Coordination__PipelineLock_lock_ownership["Woods::Coordination::PipelineLock#lock_ownership"]
  JSON_parse___["JSON.parse.[]"]
  Woods__Coordination__PipelineLock_lock_ownership -->|method_call| JSON_parse___
  JSON_parse["JSON.parse"]
  Woods__Coordination__PipelineLock_lock_ownership -->|method_call| JSON_parse
  Woods__Coordination__PipelineLock_lock_ownership -->|method_call| JSON
  Woods__Coordination__PipelineLock_own_lock_["Woods::Coordination::PipelineLock#own_lock?"]
  Woods__Coordination__PipelineLock_own_lock_ -->|method_call| JSON_parse___
  Woods__Coordination__PipelineLock_own_lock_ -->|method_call| JSON_parse
  Woods__Coordination__PipelineLock_own_lock_ -->|method_call| JSON
  Woods__Coordination__PipelineLock_restore_lock_unlocked["Woods::Coordination::PipelineLock#restore_lock_unlocked"]
  Woods__Coordination__PipelineLock_restore_lock_unlocked -->|method_call| File
  Woods__Coordination__PipelineLock_restore_lock_unlocked -->|method_call| FileUtils
  Woods__Coordination__PipelineLock_stale_file_["Woods::Coordination::PipelineLock#stale_file?"]
  Time_now__["Time.now.-"]
  Woods__Coordination__PipelineLock_stale_file_ -->|method_call| Time_now__
  Woods__Coordination__PipelineLock_stale_file_ -->|method_call| Time_now
  Woods__Coordination__PipelineLock_stale_file_ -->|method_call| Time
  Woods__Coordination__PipelineLock_lock_content["Woods::Coordination::PipelineLock#lock_content"]
  SecureRandom["SecureRandom"]
  Woods__Coordination__PipelineLock_lock_content -->|method_call| SecureRandom
  Woods__Coordination__PipelineLock_lock_content -->|method_call| JSON
  Woods__CostModel["Woods::CostModel"]
  Woods__CostModel__EmbeddingCost["Woods::CostModel::EmbeddingCost"]
  Woods__CostModel__EmbeddingCost_initialize["Woods::CostModel::EmbeddingCost#initialize"]
  ProviderPricing["ProviderPricing"]
  Woods__CostModel__EmbeddingCost_initialize -->|method_call| ProviderPricing
  Woods__CostModel__EmbeddingCost_full_index_cost["Woods::CostModel::EmbeddingCost#full_index_cost"]
  Woods__CostModel__EmbeddingCost_incremental_cost["Woods::CostModel::EmbeddingCost#incremental_cost"]
  Woods__CostModel__EmbeddingCost_monthly_query_cost["Woods::CostModel::EmbeddingCost#monthly_query_cost"]
  Woods__CostModel__EmbeddingCost_yearly_incremental_cost["Woods::CostModel::EmbeddingCost#yearly_incremental_cost"]
  Woods__CostModel__EmbeddingCost_total_tokens["Woods::CostModel::EmbeddingCost#total_tokens"]
  Woods__CostModel__EmbeddingCost_token_cost["Woods::CostModel::EmbeddingCost#token_cost"]
  Woods__CostModel__Estimator["Woods::CostModel::Estimator"]
  Woods__CostModel__Estimator_initialize["Woods::CostModel::Estimator#initialize"]
  Woods__CostModel__Estimator_initialize -->|method_call| ProviderPricing
  EmbeddingCost["EmbeddingCost"]
  Woods__CostModel__Estimator_initialize -->|method_call| EmbeddingCost
  StorageCost["StorageCost"]
  Woods__CostModel__Estimator_initialize -->|method_call| StorageCost
  Woods__CostModel__Estimator_full_index_cost["Woods::CostModel::Estimator#full_index_cost"]
  Woods__CostModel__Estimator_incremental_per_merge_cost["Woods::CostModel::Estimator#incremental_per_merge_cost"]
  Woods__CostModel__Estimator_monthly_query_cost["Woods::CostModel::Estimator#monthly_query_cost"]
  Woods__CostModel__Estimator_yearly_incremental_cost["Woods::CostModel::Estimator#yearly_incremental_cost"]
  Woods__CostModel__Estimator_total_chunks["Woods::CostModel::Estimator#total_chunks"]
  Woods__CostModel__Estimator_storage_bytes["Woods::CostModel::Estimator#storage_bytes"]
  Woods__CostModel__Estimator_storage_mb["Woods::CostModel::Estimator#storage_mb"]
  Woods__CostModel__Estimator_to_h["Woods::CostModel::Estimator#to_h"]
  Woods__CostModel__ProviderPricing["Woods::CostModel::ProviderPricing"]
  Woods__CostModel__ProviderPricing_cost_per_million["Woods::CostModel::ProviderPricing.cost_per_million"]
  COSTS_PER_MILLION_TOKENS["COSTS_PER_MILLION_TOKENS"]
  Woods__CostModel__ProviderPricing_cost_per_million -->|method_call| COSTS_PER_MILLION_TOKENS
  Woods__CostModel__ProviderPricing_default_dimensions["Woods::CostModel::ProviderPricing.default_dimensions"]
  DEFAULT_DIMENSIONS["DEFAULT_DIMENSIONS"]
  Woods__CostModel__ProviderPricing_default_dimensions -->|method_call| DEFAULT_DIMENSIONS
  Woods__CostModel__ProviderPricing_providers["Woods::CostModel::ProviderPricing.providers"]
  Woods__CostModel__ProviderPricing_providers -->|method_call| COSTS_PER_MILLION_TOKENS
  Woods__CostModel__StorageCost["Woods::CostModel::StorageCost"]
  Woods__CostModel__StorageCost_initialize["Woods::CostModel::StorageCost#initialize"]
  Woods__CostModel__StorageCost_bytes_per_vector["Woods::CostModel::StorageCost#bytes_per_vector"]
  Woods__CostModel__StorageCost_storage_bytes["Woods::CostModel::StorageCost#storage_bytes"]
  Woods__CostModel__StorageCost_storage_mb["Woods::CostModel::StorageCost#storage_mb"]
  Woods__Db["Woods::Db"]
  Woods__Db__Migrations["Woods::Db::Migrations"]
  Woods__Db__Migrations__CreateUnits["Woods::Db::Migrations::CreateUnits"]
  Woods__Db__Migrations__CreateUnits_up["Woods::Db::Migrations::CreateUnits.up"]
  Woods__Db__Migrations__CreateEdges["Woods::Db::Migrations::CreateEdges"]
  Woods__Db__Migrations__CreateEdges_up["Woods::Db::Migrations::CreateEdges.up"]
  Woods__Db__Migrations__CreateEmbeddings["Woods::Db::Migrations::CreateEmbeddings"]
  Woods__Db__Migrations__CreateEmbeddings_up["Woods::Db::Migrations::CreateEmbeddings.up"]
  Woods__Db__Migrations__CreateSnapshots["Woods::Db::Migrations::CreateSnapshots"]
  Woods__Db__Migrations__CreateSnapshots_up["Woods::Db::Migrations::CreateSnapshots.up"]
  Woods__Db__Migrations__CreateSnapshotUnits["Woods::Db::Migrations::CreateSnapshotUnits"]
  Woods__Db__Migrations__CreateSnapshotUnits_up["Woods::Db::Migrations::CreateSnapshotUnits.up"]
  Woods__Db__Migrations__RenameTables["Woods::Db::Migrations::RenameTables"]
  Woods__Db__Migrations__RenameTables_up["Woods::Db::Migrations::RenameTables.up"]
  Woods__Db__Migrator["Woods::Db::Migrator"]
  Woods__Db__Migrator_initialize["Woods::Db::Migrator#initialize"]
  SchemaVersion["SchemaVersion"]
  Woods__Db__Migrator_initialize -->|method_call| SchemaVersion
  Woods__Db__Migrator_migrate_["Woods::Db::Migrator#migrate!"]
  Woods__Db__Migrator_pending_migrations["Woods::Db::Migrator#pending_migrations"]
  MIGRATIONS["MIGRATIONS"]
  Woods__Db__Migrator_pending_migrations -->|method_call| MIGRATIONS
  Woods__Db__SchemaVersion["Woods::Db::SchemaVersion"]
  Woods__Db__SchemaVersion_initialize["Woods::Db::SchemaVersion#initialize"]
  Woods__Db__SchemaVersion_ensure_table_["Woods::Db::SchemaVersion#ensure_table!"]
  Woods__Db__SchemaVersion_applied_versions["Woods::Db::SchemaVersion#applied_versions"]
  Woods__Db__SchemaVersion_record_version["Woods::Db::SchemaVersion#record_version"]
  Woods__Db__SchemaVersion_applied_["Woods::Db::SchemaVersion#applied?"]
  Woods__Db__SchemaVersion_current_version["Woods::Db::SchemaVersion#current_version"]
  Woods__DependencyGraph["Woods::DependencyGraph"]
  Woods__DependencyGraph_initialize["Woods::DependencyGraph#initialize"]
  Woods__DependencyGraph_register["Woods::DependencyGraph#register"]
  Woods__DependencyGraph_register -->|method_call| Set
  Woods__DependencyGraph_unregister["Woods::DependencyGraph#unregister"]
  Woods__DependencyGraph_withdraw_reverse_edges["Woods::DependencyGraph#withdraw_reverse_edges"]
  Woods__DependencyGraph_withdraw_reverse_edges -->|method_call| Array
  Woods__DependencyGraph_surviving_edges["Woods::DependencyGraph#surviving_edges"]
  Woods__DependencyGraph_drop_from_file_map["Woods::DependencyGraph#drop_from_file_map"]
  Woods__DependencyGraph_drop_from_type_index["Woods::DependencyGraph#drop_from_type_index"]
  Woods__DependencyGraph_registered_types["Woods::DependencyGraph#registered_types"]
  Woods__DependencyGraph_remove["Woods::DependencyGraph#remove"]
  Woods__DependencyGraph_remove_all["Woods::DependencyGraph#remove_all"]
  Woods__DependencyGraph_identifiers_for_path["Woods::DependencyGraph#identifiers_for_path"]
  Woods__DependencyGraph_registered_paths["Woods::DependencyGraph#registered_paths"]
  Woods__DependencyGraph_affected_by["Woods::DependencyGraph#affected_by"]
  Woods__DependencyGraph_affected_by -->|method_call| Set
  Woods__DependencyGraph_node["Woods::DependencyGraph#node"]
  Woods__DependencyGraph_nodes_for["Woods::DependencyGraph#nodes_for"]
  Woods__DependencyGraph_node_types["Woods::DependencyGraph#node_types"]
  Woods__DependencyGraph_units_for_path["Woods::DependencyGraph#units_for_path"]
  Woods__DependencyGraph_sorted_nodes["Woods::DependencyGraph#sorted_nodes"]
  Woods__DependencyGraph_primary_of["Woods::DependencyGraph#primary_of"]
  Woods__DependencyGraph_node_exists_["Woods::DependencyGraph#node_exists?"]
  Woods__DependencyGraph_find_node_by_suffix["Woods::DependencyGraph#find_node_by_suffix"]
  Woods__DependencyGraph_find_all_by_suffix["Woods::DependencyGraph#find_all_by_suffix"]
  Woods__DependencyGraph_dependencies_of["Woods::DependencyGraph#dependencies_of"]
  Woods__DependencyGraph_edges_for["Woods::DependencyGraph#edges_for"]
  Woods__DependencyGraph_dependents_of["Woods::DependencyGraph#dependents_of"]
  Array_each_with_object["Array.each_with_object"]
  Woods__DependencyGraph_dependents_of -->|method_call| Array_each_with_object
  Woods__DependencyGraph_dependents_of -->|method_call| Array
  Woods__DependencyGraph_dependents_detail["Woods::DependencyGraph#dependents_detail"]
  Woods__DependencyGraph_dependents_detail -->|method_call| Array
  Woods__DependencyGraph_units_of_type["Woods::DependencyGraph#units_of_type"]
  Woods__DependencyGraph_pagerank["Woods::DependencyGraph#pagerank"]
  Woods__DependencyGraph_suffix_groups["Woods::DependencyGraph#suffix_groups"]
  Woods__DependencyGraph_pagerank_step["Woods::DependencyGraph#pagerank_step"]
  Woods__DependencyGraph_resolvable_edge_weights["Woods::DependencyGraph#resolvable_edge_weights"]
  Hash["Hash"]
  Woods__DependencyGraph_resolvable_edge_weights -->|method_call| Hash
  Woods__DependencyGraph_to_h["Woods::DependencyGraph#to_h"]
  Woods__DependencyGraph_primary_nodes["Woods::DependencyGraph#primary_nodes"]
  Woods__DependencyGraph_primary_edges["Woods::DependencyGraph#primary_edges"]
  Woods__DependencyGraph_variant_records["Woods::DependencyGraph#variant_records"]
  Woods__DependencyGraph_primary_type_for["Woods::DependencyGraph#primary_type_for"]
  Woods__DependencyGraph_graph_root["Woods::DependencyGraph.graph_root"]
  Woods__DependencyGraph_graph_root -->|method_call| Rails
  Rails_root["Rails.root"]
  Woods__DependencyGraph_graph_root -->|method_call| Rails_root
  Woods__DependencyGraph_relativize["Woods::DependencyGraph.relativize"]
  Woods__DependencyGraph_absolutize["Woods::DependencyGraph.absolutize"]
  Woods__DependencyGraph_absolutize -->|method_call| File
  Woods__DependencyGraph_relativize_nodes["Woods::DependencyGraph.relativize_nodes"]
  Woods__DependencyGraph_absolutize_nodes["Woods::DependencyGraph.absolutize_nodes"]
  Woods__DependencyGraph_relativize_variants["Woods::DependencyGraph.relativize_variants"]
  Woods__DependencyGraph_relativize_file_map["Woods::DependencyGraph.relativize_file_map"]
  Woods__DependencyGraph_absolutize_file_map["Woods::DependencyGraph.absolutize_file_map"]
  Woods__DependencyGraph_relocate_file_map["Woods::DependencyGraph.relocate_file_map"]
  Woods__DependencyGraph_relocate_file_map -->|method_call| Set
  Woods__DependencyGraph_from_h["Woods::DependencyGraph.from_h"]
  Woods__DependencyGraph_from_h -->|method_call| Set
  Woods__DependencyGraph_merge_variants["Woods::DependencyGraph.merge_variants"]
  Woods__DependencyGraph_normalize_file_map["Woods::DependencyGraph.normalize_file_map"]
  Woods__DependencyGraph_symbolize_node["Woods::DependencyGraph.symbolize_node"]
  Woods__DependencyGraph_normalize_edges["Woods::DependencyGraph.normalize_edges"]
  Woods__Embedding["Woods::Embedding"]
  Woods__Embedding__Provider["Woods::Embedding::Provider"]
  Woods__Embedding__Provider__Fake["Woods::Embedding::Provider::Fake"]
  Interface["Interface"]
  Woods__Embedding__Provider__Fake -->|include| Interface
  Woods__Embedding__Provider__Fake_initialize["Woods::Embedding::Provider::Fake#initialize"]
  Woods__Embedding__Provider__Fake_embed["Woods::Embedding::Provider::Fake#embed"]
  Woods__Embedding__Provider__Fake_embed_batch["Woods::Embedding::Provider::Fake#embed_batch"]
  Woods__Embedding__Provider__Fake_dimensions["Woods::Embedding::Provider::Fake#dimensions"]
  Woods__Embedding__Provider__Fake_model_name["Woods::Embedding::Provider::Fake#model_name"]
  Woods__Embedding__Provider__Fake_max_input_tokens["Woods::Embedding::Provider::Fake#max_input_tokens"]
  Woods__Embedding__Provider__Fake_text_to_vector["Woods::Embedding::Provider::Fake#text_to_vector"]
  Woods__Embedding__Provider__Fake_text_to_vector -->|method_call| Array
  Digest__SHA256_hexdigest_to_i["Digest::SHA256.hexdigest.to_i"]
  Woods__Embedding__Provider__Fake_text_to_vector -->|method_call| Digest__SHA256_hexdigest_to_i
  Digest__SHA256_hexdigest["Digest::SHA256.hexdigest"]
  Woods__Embedding__Provider__Fake_text_to_vector -->|method_call| Digest__SHA256_hexdigest
  Woods__Embedding__Provider__Fake_text_to_vector -->|method_call| Digest__SHA256
  Woods__Embedding__Provider__Fake_normalize["Woods::Embedding::Provider::Fake#normalize"]
  Math["Math"]
  Woods__Embedding__Provider__Fake_normalize -->|method_call| Math
  Woods__Embedding__Indexer["Woods::Embedding::Indexer"]
  Woods__Embedding__Indexer__ChunkSuffixCollision["Woods::Embedding::Indexer::ChunkSuffixCollision"]
  Woods__Embedding__Indexer__ChunkSuffixCollision -->|inheritance| Woods__Error
  Woods__Embedding__Indexer__ChunkSuffixCollision_initialize["Woods::Embedding::Indexer::ChunkSuffixCollision#initialize"]
  Woods__Embedding__Indexer_initialize["Woods::Embedding::Indexer#initialize"]
  Woods__Embedding__Indexer_index_all["Woods::Embedding::Indexer#index_all"]
  Woods__Embedding__Indexer_index_incremental["Woods::Embedding::Indexer#index_incremental"]
  Woods__Embedding__Indexer_units_dir["Woods::Embedding::Indexer#units_dir"]
  Woods__Generation_new_payload_dir["Woods::Generation.new.payload_dir"]
  Woods__Embedding__Indexer_units_dir -->|method_call| Woods__Generation_new_payload_dir
  Woods__Generation_new["Woods::Generation.new"]
  Woods__Embedding__Indexer_units_dir -->|method_call| Woods__Generation_new
  Woods__Generation["Woods::Generation"]
  Woods__Embedding__Indexer_units_dir -->|method_call| Woods__Generation
  Woods__Embedding__Indexer_load_units["Woods::Embedding::Indexer#load_units"]
  Dir_glob["Dir.glob"]
  Woods__Embedding__Indexer_load_units -->|method_call| Dir_glob
  File_basename["File.basename"]
  Woods__Embedding__Indexer_load_units -->|method_call| File_basename
  Woods__Embedding__Indexer_load_units -->|method_call| File
  Woods__Embedding__Indexer_load_units -->|method_call| JSON
  Woods__Embedding__Indexer_process_units["Woods::Embedding::Indexer#process_units"]
  Woods__Embedding__Indexer_snapshot_worth_writing_["Woods::Embedding::Indexer#snapshot_worth_writing?"]
  Woods__Embedding__Indexer_drop_vanished_units["Woods::Embedding::Indexer#drop_vanished_units"]
  Woods__Embedding__Indexer_vanished_prune_permitted_["Woods::Embedding::Indexer#vanished_prune_permitted?"]
  Woods__Embedding__Indexer_warn_empty_load_refusal["Woods::Embedding::Indexer#warn_empty_load_refusal"]
  Woods__Embedding__Indexer_purge_override_["Woods::Embedding::Indexer#purge_override?"]
  ENV_fetch["ENV.fetch"]
  Woods__Embedding__Indexer_purge_override_ -->|method_call| ENV_fetch
  ENV["ENV"]
  Woods__Embedding__Indexer_purge_override_ -->|method_call| ENV
  Woods__Embedding__Indexer_reconcile_durable_store["Woods::Embedding::Indexer#reconcile_durable_store"]
  Woods__Embedding__Indexer_vanished_durable_identifiers["Woods::Embedding::Indexer#vanished_durable_identifiers"]
  Woods__Embedding__Indexer_delete_durable_identifiers["Woods::Embedding::Indexer#delete_durable_identifiers"]
  Woods__Embedding__Indexer_durable_prune_permitted_["Woods::Embedding::Indexer#durable_prune_permitted?"]
  Woods__Embedding__Indexer_prepare_run["Woods::Embedding::Indexer#prepare_run"]
  Woods__Embedding__Indexer_prepare_run -->|method_call| Set
  Woods__Embedding__Indexer_load_durable_store_ids["Woods::Embedding::Indexer#load_durable_store_ids"]
  Woods__Embedding__Indexer_load_durable_store_ids -->|method_call| Hash
  Woods__Embedding__Indexer_base_identifier["Woods::Embedding::Indexer#base_identifier"]
  Woods__Embedding__Indexer_reconcilable_["Woods::Embedding::Indexer#reconcilable?"]
  Woods__Embedding__Indexer_embed_batches["Woods::Embedding::Indexer#embed_batches"]
  Woods__Embedding__Indexer_report_checkpoint_misses["Woods::Embedding::Indexer#report_checkpoint_misses"]
  Woods__Embedding__Indexer_interval_checkpoints_["Woods::Embedding::Indexer#interval_checkpoints?"]
  Woods__Embedding__Indexer_process_batch["Woods::Embedding::Indexer#process_batch"]
  Woods__Embedding__Indexer_checkpoint_satisfied_["Woods::Embedding::Indexer#checkpoint_satisfied?"]
  Woods__Embedding__Indexer_persist_unit_metadata["Woods::Embedding::Indexer#persist_unit_metadata"]
  Woods__Embedding__Indexer_reject_chunk_suffix_collision_["Woods::Embedding::Indexer#reject_chunk_suffix_collision!"]
  Woods__Embedding__Indexer_collect_embed_items["Woods::Embedding::Indexer#collect_embed_items"]
  Woods__Embedding__Indexer_prepare_texts["Woods::Embedding::Indexer#prepare_texts"]
  Woods__Embedding__Indexer_content_portion_empty_["Woods::Embedding::Indexer#content_portion_empty?"]
  Woods__Embedding__Indexer_needs_chunking_["Woods::Embedding::Indexer#needs_chunking?"]
  Woods__Embedding__Indexer_chunker_token_oversize_["Woods::Embedding::Indexer#chunker_token_oversize?"]
  Woods__Embedding__Indexer_apply_chunking["Woods::Embedding::Indexer#apply_chunking"]
  Woods__Embedding__Indexer_build_unit["Woods::Embedding::Indexer#build_unit"]
  ExtractedUnit["ExtractedUnit"]
  Woods__Embedding__Indexer_build_unit -->|method_call| ExtractedUnit
  Woods__Embedding__Indexer_embed_and_store["Woods::Embedding::Indexer#embed_and_store"]
  Woods__Embedding__Indexer_store_vectors["Woods::Embedding::Indexer#store_vectors"]
  Woods__Embedding__Indexer_hydrate_persisted_vectors["Woods::Embedding::Indexer#hydrate_persisted_vectors"]
  Storage__Snapshotter__Vector["Storage::Snapshotter::Vector"]
  Woods__Embedding__Indexer_hydrate_persisted_vectors -->|method_call| Storage__Snapshotter__Vector
  Woods__Embedding__Indexer_index_ids_by_identifier["Woods::Embedding::Indexer#index_ids_by_identifier"]
  Woods__Embedding__Indexer_prune_superseded_vectors["Woods::Embedding::Indexer#prune_superseded_vectors"]
  Woods__Embedding__Indexer_prune_identifier["Woods::Embedding::Indexer#prune_identifier"]
  Woods__Embedding__Indexer_prune_superseded_durable_vectors["Woods::Embedding::Indexer#prune_superseded_durable_vectors"]
  Woods__Embedding__Indexer_prune_durable_identifier["Woods::Embedding::Indexer#prune_durable_identifier"]
  Woods__Embedding__Indexer_load_checkpoint["Woods::Embedding::Indexer#load_checkpoint"]
  Woods__Embedding__Indexer_load_checkpoint -->|method_call| File
  Woods__Embedding__Indexer_save_checkpoint["Woods::Embedding::Indexer#save_checkpoint"]
  AtomicFile["AtomicFile"]
  Woods__Embedding__Indexer_save_checkpoint -->|method_call| AtomicFile
  Woods__Embedding__Indexer_current_checkpoint_identity["Woods::Embedding::Indexer#current_checkpoint_identity"]
  Woods__Embedding__Indexer_checkpoint_payload["Woods::Embedding::Indexer#checkpoint_payload"]
  Woods__Embedding__Indexer_checkpoint_hashes["Woods::Embedding::Indexer#checkpoint_hashes"]
  Woods__Embedding__Indexer_checkpoint_hashes_versioned["Woods::Embedding::Indexer#checkpoint_hashes_versioned"]
  Woods__Embedding__Indexer_persistable_["Woods::Embedding::Indexer#persistable?"]
  Woods__Embedding__Indexer_safe_max_input_tokens["Woods::Embedding::Indexer#safe_max_input_tokens"]
  Woods__Embedding__Indexer_implements_own_["Woods::Embedding::Indexer#implements_own?"]
  Woods__Embedding__Indexer_persist_snapshot["Woods::Embedding::Indexer#persist_snapshot"]
  IndexArtifact["IndexArtifact"]
  Woods__Embedding__Indexer_persist_snapshot -->|method_call| IndexArtifact
  Woods__Embedding__Indexer_persist_snapshot -->|method_call| Storage__Snapshotter__Vector
  Storage__Snapshotter__Metadata["Storage::Snapshotter::Metadata"]
  Woods__Embedding__Indexer_persist_snapshot -->|method_call| Storage__Snapshotter__Metadata
  Woods__Embedding__Indexer_unique_dump_dir["Woods::Embedding::Indexer#unique_dump_dir"]
  Woods__Embedding__Indexer_unique_dump_dir -->|method_call| Time_now
  Woods__Embedding__Indexer_unique_dump_dir -->|method_call| Time
  Woods__Embedding__Indexer_prune_old_dumps["Woods::Embedding::Indexer#prune_old_dumps"]
  Woods__Embedding__Indexer_prune_old_dumps -->|method_call| FileUtils
  Woods__Embedding__Indexer_sorted_dump_dirs["Woods::Embedding::Indexer#sorted_dump_dirs"]
  Woods__Embedding__Provider__OpenAI["Woods::Embedding::Provider::OpenAI"]
  Woods__Embedding__Provider__OpenAI -->|include| Interface
  Woods__Embedding__Provider__OpenAI_initialize["Woods::Embedding::Provider::OpenAI#initialize"]
  Woods__Embedding__Provider__OpenAI_embed["Woods::Embedding::Provider::OpenAI#embed"]
  Woods__Embedding__Provider__OpenAI_embed -->|method_call| Array
  VectorValidation["VectorValidation"]
  Woods__Embedding__Provider__OpenAI_embed -->|method_call| VectorValidation
  Woods__Embedding__Provider__OpenAI_embed_batch["Woods::Embedding::Provider::OpenAI#embed_batch"]
  Woods__Embedding__Provider__OpenAI_dimensions["Woods::Embedding::Provider::OpenAI#dimensions"]
  DIMENSIONS["DIMENSIONS"]
  Woods__Embedding__Provider__OpenAI_dimensions -->|method_call| DIMENSIONS
  Woods__Embedding__Provider__OpenAI_model_name["Woods::Embedding::Provider::OpenAI#model_name"]
  Woods__Embedding__Provider__OpenAI_max_input_tokens["Woods::Embedding::Provider::OpenAI#max_input_tokens"]
  Woods__Embedding__Provider__OpenAI_extract_validated_batch["Woods::Embedding::Provider::OpenAI#extract_validated_batch"]
  Woods__Embedding__Provider__OpenAI_extract_validated_batch -->|method_call| VectorValidation
  Woods__Embedding__Provider__OpenAI_request_body["Woods::Embedding::Provider::OpenAI#request_body"]
  Woods__Embedding__Provider__OpenAI_normalize_dimensions["Woods::Embedding::Provider::OpenAI#normalize_dimensions"]
  Woods__Embedding__Provider__OpenAI_truncate_response_body["Woods::Embedding::Provider::OpenAI#truncate_response_body"]
  Woods__Embedding__Provider__OpenAI_post_request["Woods::Embedding::Provider::OpenAI#post_request"]
  Net__HTTP__Post["Net::HTTP::Post"]
  Woods__Embedding__Provider__OpenAI_post_request -->|method_call| Net__HTTP__Post
  Woods__Embedding__Provider__OpenAI_post_request -->|method_call| JSON
  Woods__Embedding__Provider__OpenAI_request_error["Woods::Embedding::Provider::OpenAI#request_error"]
  RequestError["RequestError"]
  Woods__Embedding__Provider__OpenAI_request_error -->|method_call| RequestError
  Woods__Embedding__Provider__OpenAI_http_client["Woods::Embedding::Provider::OpenAI#http_client"]
  Net__HTTP["Net::HTTP"]
  Woods__Embedding__Provider__OpenAI_http_client -->|method_call| Net__HTTP
  Woods__Embedding__Provider__Interface["Woods::Embedding::Provider::Interface"]
  Woods__Embedding__Provider__RequestError["Woods::Embedding::Provider::RequestError"]
  Woods__Embedding__Provider__RequestError -->|inheritance| Woods__Error
  Woods__Embedding__Provider__InvalidEmbeddingResponse["Woods::Embedding::Provider::InvalidEmbeddingResponse"]
  Woods__Embedding__Provider__InvalidEmbeddingResponse -->|inheritance| Woods__Error
  Woods__Embedding__Provider__VectorValidation["Woods::Embedding::Provider::VectorValidation"]
  Woods__Embedding__Provider__Ollama["Woods::Embedding::Provider::Ollama"]
  Woods__Embedding__Provider__Ollama -->|include| Interface
  Woods__Embedding__Provider__Interface_embed["Woods::Embedding::Provider::Interface#embed"]
  Woods__Embedding__Provider__Interface_embed_batch["Woods::Embedding::Provider::Interface#embed_batch"]
  Woods__Embedding__Provider__Interface_dimensions["Woods::Embedding::Provider::Interface#dimensions"]
  Woods__Embedding__Provider__Interface_model_name["Woods::Embedding::Provider::Interface#model_name"]
  Woods__Embedding__Provider__Interface_max_input_tokens["Woods::Embedding::Provider::Interface#max_input_tokens"]
  Woods__Embedding__Provider__RequestError_initialize["Woods::Embedding::Provider::RequestError#initialize"]
  Woods__Embedding__Provider__InvalidEmbeddingResponse_initialize["Woods::Embedding::Provider::InvalidEmbeddingResponse#initialize"]
  Woods__Embedding__Provider__VectorValidation_validate_["Woods::Embedding::Provider::VectorValidation#validate!"]
  Woods__Embedding__Provider__VectorValidation_validate_indexes_["Woods::Embedding::Provider::VectorValidation#validate_indexes!"]
  Woods__Embedding__Provider__VectorValidation_validate_vector_shapes_["Woods::Embedding::Provider::VectorValidation#validate_vector_shapes!"]
  Woods__Embedding__Provider__VectorValidation_check_vector_shape_["Woods::Embedding::Provider::VectorValidation#check_vector_shape!"]
  Woods__Embedding__Provider__Ollama_initialize["Woods::Embedding::Provider::Ollama#initialize"]
  MODEL_CONTEXT_LENGTHS["MODEL_CONTEXT_LENGTHS"]
  Woods__Embedding__Provider__Ollama_initialize -->|method_call| MODEL_CONTEXT_LENGTHS
  Woods__Embedding__Provider__Ollama_embed["Woods::Embedding::Provider::Ollama#embed"]
  Woods__Embedding__Provider__Ollama_embed -->|method_call| VectorValidation
  Woods__Embedding__Provider__Ollama_embed_batch["Woods::Embedding::Provider::Ollama#embed_batch"]
  Woods__Embedding__Provider__Ollama_embed_batch -->|method_call| VectorValidation
  Woods__Embedding__Provider__Ollama_dimensions["Woods::Embedding::Provider::Ollama#dimensions"]
  Woods__Embedding__Provider__Ollama_model_name["Woods::Embedding::Provider::Ollama#model_name"]
  Woods__Embedding__Provider__Ollama_max_input_tokens["Woods::Embedding::Provider::Ollama#max_input_tokens"]
  Woods__Embedding__Provider__Ollama_normalize_dimensions["Woods::Embedding::Provider::Ollama#normalize_dimensions"]
  Woods__Embedding__Provider__Ollama_truncate_response_body["Woods::Embedding::Provider::Ollama#truncate_response_body"]
  Woods__Embedding__Provider__Ollama_build_body["Woods::Embedding::Provider::Ollama#build_body"]
  Woods__Embedding__Provider__Ollama_post_request["Woods::Embedding::Provider::Ollama#post_request"]
  Woods__Embedding__Provider__Ollama_post_request -->|method_call| Net__HTTP__Post
  Woods__Embedding__Provider__Ollama_post_request -->|method_call| JSON
  Woods__Embedding__Provider__Ollama_request_error["Woods::Embedding::Provider::Ollama#request_error"]
  Woods__Embedding__Provider__Ollama_request_error -->|method_call| RequestError
  Woods__Embedding__Provider__Ollama_http_client["Woods::Embedding::Provider::Ollama#http_client"]
  Woods__Embedding__Provider__Ollama_http_client -->|method_call| Net__HTTP
  Woods__Embedding__TextPreparer["Woods::Embedding::TextPreparer"]
  Woods__Embedding__TextPreparer_initialize["Woods::Embedding::TextPreparer#initialize"]
  Woods__Embedding__TextPreparer_prepare["Woods::Embedding::TextPreparer#prepare"]
  Woods__Embedding__TextPreparer_prepare_chunks["Woods::Embedding::TextPreparer#prepare_chunks"]
  Woods__Embedding__TextPreparer_build_prefix["Woods::Embedding::TextPreparer#build_prefix"]
  Woods__Embedding__TextPreparer_append_dependency_line["Woods::Embedding::TextPreparer#append_dependency_line"]
  Woods__Embedding__TextPreparer_select_content["Woods::Embedding::TextPreparer#select_content"]
  Woods__Embedding__TextPreparer_enforce_token_limit["Woods::Embedding::TextPreparer#enforce_token_limit"]
  Woods__Embedding__TokenCounter["Woods::Embedding::TokenCounter"]
  Woods__Embedding__TokenCounter_initialize["Woods::Embedding::TokenCounter#initialize"]
  Woods__Embedding__TokenCounter_initialize -->|method_call| Mutex
  Woods__Embedding__TokenCounter_count["Woods::Embedding::TokenCounter#count"]
  Woods__Embedding__TokenCounter_estimate["Woods::Embedding::TokenCounter#estimate"]
  Woods__Embedding__TokenCounter_tokenizer["Woods::Embedding::TokenCounter#tokenizer"]
  Woods__Embedding__TokenCounter_try_load["Woods::Embedding::TokenCounter#try_load"]
  Tokenizers["Tokenizers"]
  Woods__Embedding__TokenCounter_try_load -->|method_call| Tokenizers
  Woods__Embedding__TokenCounter_warn_once["Woods::Embedding::TokenCounter#warn_once"]
  Kernel["Kernel"]
  Woods__Embedding__TokenCounter_warn_once -->|method_call| Kernel
  Woods__Evaluation["Woods::Evaluation"]
  Woods__Evaluation__Baseline["Woods::Evaluation::Baseline"]
  Woods__Evaluation__BaselineRunner["Woods::Evaluation::BaselineRunner"]
  Woods__Evaluation__BaselineRunner_initialize["Woods::Evaluation::BaselineRunner#initialize"]
  Random["Random"]
  Woods__Evaluation__BaselineRunner_initialize -->|method_call| Random
  Woods__Evaluation__BaselineRunner_initialize -->|method_call| Mutex
  Woods__Evaluation__BaselineRunner_run["Woods::Evaluation::BaselineRunner#run"]
  VALID_STRATEGIES["VALID_STRATEGIES"]
  Woods__Evaluation__BaselineRunner_run -->|method_call| VALID_STRATEGIES
  Woods__Evaluation__BaselineRunner_run_grep["Woods::Evaluation::BaselineRunner#run_grep"]
  Woods__Evaluation__BaselineRunner_run_random["Woods::Evaluation::BaselineRunner#run_random"]
  Woods__Evaluation__BaselineRunner_run_file_level["Woods::Evaluation::BaselineRunner#run_file_level"]
  Woods__Evaluation__BaselineRunner_extract_keywords["Woods::Evaluation::BaselineRunner#extract_keywords"]
  Woods__Evaluation__Evaluator["Woods::Evaluation::Evaluator"]
  Woods__Evaluation__Evaluator_initialize["Woods::Evaluation::Evaluator#initialize"]
  Woods__Evaluation__Evaluator_evaluate["Woods::Evaluation::Evaluator#evaluate"]
  EvaluationReport["EvaluationReport"]
  Woods__Evaluation__Evaluator_evaluate -->|method_call| EvaluationReport
  Woods__Evaluation__Evaluator_evaluate_thresholds["Woods::Evaluation::Evaluator#evaluate_thresholds"]
  ThresholdReport["ThresholdReport"]
  Woods__Evaluation__Evaluator_evaluate_thresholds -->|method_call| ThresholdReport
  Woods__Evaluation__Evaluator_evaluate_query["Woods::Evaluation::Evaluator#evaluate_query"]
  QueryResult["QueryResult"]
  Woods__Evaluation__Evaluator_evaluate_query -->|method_call| QueryResult
  Woods__Evaluation__Evaluator_extract_identifiers["Woods::Evaluation::Evaluator#extract_identifiers"]
  Woods__Evaluation__Evaluator_compute_scores["Woods::Evaluation::Evaluator#compute_scores"]
  Woods__Evaluation__Evaluator_compute_token_efficiency["Woods::Evaluation::Evaluator#compute_token_efficiency"]
  Metrics["Metrics"]
  Woods__Evaluation__Evaluator_compute_token_efficiency -->|method_call| Metrics
  Woods__Evaluation__Evaluator_compute_aggregates["Woods::Evaluation::Evaluator#compute_aggregates"]
  METRIC_KEYS["METRIC_KEYS"]
  Woods__Evaluation__Evaluator_compute_aggregates -->|method_call| METRIC_KEYS
  Woods__Evaluation__Evaluator_empty_aggregates["Woods::Evaluation::Evaluator#empty_aggregates"]
  METRIC_KEYS_to_h["METRIC_KEYS.to_h"]
  Woods__Evaluation__Evaluator_empty_aggregates -->|method_call| METRIC_KEYS_to_h
  Woods__Evaluation__Evaluator_empty_aggregates -->|method_call| METRIC_KEYS
  Woods__Evaluation__Metrics["Woods::Evaluation::Metrics"]
  Woods__Evaluation__Metrics_precision_at_k["Woods::Evaluation::Metrics#precision_at_k"]
  Woods__Evaluation__Metrics_recall["Woods::Evaluation::Metrics#recall"]
  Woods__Evaluation__Metrics_mrr["Woods::Evaluation::Metrics#mrr"]
  Woods__Evaluation__Metrics_context_completeness["Woods::Evaluation::Metrics#context_completeness"]
  Woods__Evaluation__Metrics_token_efficiency["Woods::Evaluation::Metrics#token_efficiency"]
  Woods__Evaluation__QuerySet["Woods::Evaluation::QuerySet"]
  Woods__Evaluation__QuerySet_initialize["Woods::Evaluation::QuerySet#initialize"]
  Woods__Evaluation__QuerySet_load["Woods::Evaluation::QuerySet.load"]
  Woods__Evaluation__QuerySet_load -->|method_call| JSON
  Woods__Evaluation__QuerySet_save["Woods::Evaluation::QuerySet#save"]
  Woods__Evaluation__QuerySet_save -->|method_call| File
  Woods__Evaluation__QuerySet_filter["Woods::Evaluation::QuerySet#filter"]
  Woods__Evaluation__QuerySet_add["Woods::Evaluation::QuerySet#add"]
  Woods__Evaluation__QuerySet_size["Woods::Evaluation::QuerySet#size"]
  Woods__Evaluation__QuerySet_parse_query["Woods::Evaluation::QuerySet.parse_query"]
  Query["Query"]
  Woods__Evaluation__QuerySet_parse_query -->|method_call| Query
  Woods__Evaluation__QuerySet_serialize_query["Woods::Evaluation::QuerySet#serialize_query"]
  Woods__Evaluation__QuerySet_validate_query_["Woods::Evaluation::QuerySet#validate_query!"]
  VALID_INTENTS["VALID_INTENTS"]
  Woods__Evaluation__QuerySet_validate_query_ -->|method_call| VALID_INTENTS
  VALID_SCOPES["VALID_SCOPES"]
  Woods__Evaluation__QuerySet_validate_query_ -->|method_call| VALID_SCOPES
  Woods__Evaluation__ReportGenerator["Woods::Evaluation::ReportGenerator"]
  Woods__Evaluation__ReportGenerator_generate["Woods::Evaluation::ReportGenerator#generate"]
  Woods__Evaluation__ReportGenerator_generate -->|method_call| JSON
  Woods__Evaluation__ReportGenerator_save["Woods::Evaluation::ReportGenerator#save"]
  Woods__Evaluation__ReportGenerator_save -->|method_call| FileUtils
  Woods__Evaluation__ReportGenerator_save -->|method_call| File
  Woods__Evaluation__ReportGenerator_build_report_hash["Woods::Evaluation::ReportGenerator#build_report_hash"]
  Woods__Evaluation__ReportGenerator_build_metadata["Woods::Evaluation::ReportGenerator#build_metadata"]
  Woods__Evaluation__ReportGenerator_serialize_aggregates["Woods::Evaluation::ReportGenerator#serialize_aggregates"]
  Woods__Evaluation__ReportGenerator_serialize_threshold_report["Woods::Evaluation::ReportGenerator#serialize_threshold_report"]
  Woods__Evaluation__ReportGenerator_serialize_result["Woods::Evaluation::ReportGenerator#serialize_result"]
  Woods__Export["Woods::Export"]
  Woods__Export__UnitFacts["Woods::Export::UnitFacts"]
  Woods__Export__UnitFacts_initialize["Woods::Export::UnitFacts#initialize"]
  Woods__Export__UnitFacts_associations_by_type["Woods::Export::UnitFacts#associations_by_type"]
  Woods__Export__UnitFacts_association_count["Woods::Export::UnitFacts#association_count"]
  Woods__Export__UnitFacts_schema_highlights["Woods::Export::UnitFacts#schema_highlights"]
  Woods__Export__UnitFacts_enums["Woods::Export::UnitFacts#enums"]
  Woods__Export__UnitFacts_scopes["Woods::Export::UnitFacts#scopes"]
  Woods__Export__UnitFacts_concerns["Woods::Export::UnitFacts#concerns"]
  Woods__Export__UnitFacts_callbacks["Woods::Export::UnitFacts#callbacks"]
  Woods__Export__UnitFacts_associations["Woods::Export::UnitFacts#associations"]
  Woods__ExtractedUnit["Woods::ExtractedUnit"]
  Woods__ExtractedUnit_initialize["Woods::ExtractedUnit#initialize"]
  Woods__ExtractedUnit_to_h["Woods::ExtractedUnit#to_h"]
  Woods__ExtractedUnit_estimated_tokens["Woods::ExtractedUnit#estimated_tokens"]
  Woods__ExtractedUnit_serialized_metadata["Woods::ExtractedUnit#serialized_metadata"]
  Woods__ExtractedUnit_serialized_metadata -->|method_call| JSON
  Woods__ExtractedUnit_needs_chunking_["Woods::ExtractedUnit#needs_chunking?"]
  Woods__Extractor["Woods::Extractor"]
  FilenameUtils["FilenameUtils"]
  Woods__Extractor -->|include| FilenameUtils
  Woods__Extractor_initialize["Woods::Extractor#initialize"]
  Woods__Extractor_initialize -->|method_call| Pathname
  PayloadStore["PayloadStore"]
  Woods__Extractor_initialize -->|method_call| PayloadStore
  DependencyGraph["DependencyGraph"]
  Woods__Extractor_initialize -->|method_call| DependencyGraph
  Woods__Extractor_payload_dir["Woods::Extractor#payload_dir"]
  Woods__Extractor_extract_all["Woods::Extractor#extract_all"]
  ModelNameCache["ModelNameCache"]
  Woods__Extractor_extract_all -->|method_call| ModelNameCache
  Woods__Extractor_extract_all -->|method_call| Woods_configuration
  Woods__Extractor_extract_all -->|method_call| Woods
  Woods__Extractor_extract_all -->|method_call| Rails_logger
  Woods__Extractor_extract_all -->|method_call| Rails
  Woods__Extractor_extract_all -->|method_call| DependencyGraph
  GraphAnalyzer_new["GraphAnalyzer.new"]
  Woods__Extractor_extract_all -->|method_call| GraphAnalyzer_new
  GraphAnalyzer["GraphAnalyzer"]
  Woods__Extractor_extract_all -->|method_call| GraphAnalyzer
  Woods__Extractor_extract_changed["Woods::Extractor#extract_changed"]
  ChangeSet["ChangeSet"]
  Woods__Extractor_extract_changed -->|method_call| ChangeSet
  Woods__Extractor_extract_changed -->|method_call| Set
  Woods__Extractor_extract_changed -->|method_call| Rails_logger
  Woods__Extractor_extract_changed -->|method_call| Rails
  Woods__Extractor_refresh["Woods::Extractor#refresh"]
  Array_flatten_map["Array.flatten.map"]
  Woods__Extractor_refresh -->|method_call| Array_flatten_map
  Array_flatten["Array.flatten"]
  Woods__Extractor_refresh -->|method_call| Array_flatten
  Woods__Extractor_refresh -->|method_call| Array
  EXTRACTORS["EXTRACTORS"]
  Woods__Extractor_refresh -->|method_call| EXTRACTORS
  Woods__Extractor_refresh -->|method_call| Set
  Woods__Extractor_prepare_incremental_run["Woods::Extractor#prepare_incremental_run"]
  Woods__Extractor_prepare_incremental_run -->|method_call| DependencyGraph
  Woods__Extractor_prepare_incremental_run -->|method_call| ModelNameCache
  Woods__Extractor_prepare_incremental_run -->|method_call| Set
  Woods__Extractor_finalize_incremental_run["Woods::Extractor#finalize_incremental_run"]
  Woods__Extractor_finalize_incremental_run -->|method_call| Rails_logger
  Woods__Extractor_finalize_incremental_run -->|method_call| Rails
  Woods__Extractor_finalize_incremental_run -->|method_call| Woods_configuration
  Woods__Extractor_finalize_incremental_run -->|method_call| Woods
  Woods__Extractor_publish_generation["Woods::Extractor#publish_generation"]
  Generation["Generation"]
  Woods__Extractor_publish_generation -->|method_call| Generation
  Woods__Extractor_publish_generation -->|method_call| Rails_logger
  Woods__Extractor_publish_generation -->|method_call| Rails
  Woods__Extractor_begin_payload_["Woods::Extractor#begin_payload!"]
  Generation_new["Generation.new"]
  Woods__Extractor_begin_payload_ -->|method_call| Generation_new
  Woods__Extractor_begin_payload_ -->|method_call| Generation
  Woods__Extractor_begin_payload_ -->|method_call| Rails_logger
  Woods__Extractor_begin_payload_ -->|method_call| Rails
  Woods__Extractor_seed_payload["Woods::Extractor#seed_payload"]
  Woods__Extractor_seed_payload_from_flat_root["Woods::Extractor#seed_payload_from_flat_root"]
  Woods__Extractor_payload_entry_dirs["Woods::Extractor#payload_entry_dirs"]
  EXTRACTORS_keys_map["EXTRACTORS.keys.map"]
  Woods__Extractor_payload_entry_dirs -->|method_call| EXTRACTORS_keys_map
  EXTRACTORS_keys["EXTRACTORS.keys"]
  Woods__Extractor_payload_entry_dirs -->|method_call| EXTRACTORS_keys
  Woods__Extractor_payload_entry_dirs -->|method_call| EXTRACTORS
  Woods__Extractor_publishable_payload_name["Woods::Extractor#publishable_payload_name"]
  Woods__Extractor_publishable_payload_name -->|method_call| PayloadStore
  Woods__Extractor_rename_payload["Woods::Extractor#rename_payload"]
  Woods__Extractor_rename_payload -->|method_call| FileUtils
  Woods__Extractor_prune_payloads["Woods::Extractor#prune_payloads"]
  Woods__Extractor_prune_payloads -->|method_call| Rails_logger
  Woods__Extractor_prune_payloads -->|method_call| Rails
  Woods__Extractor_payload_retention["Woods::Extractor#payload_retention"]
  Woods__Extractor_payload_retention -->|method_call| ENV_fetch
  Woods__Extractor_payload_retention -->|method_call| ENV
  Woods__Extractor_write_incremental_graph_analysis["Woods::Extractor#write_incremental_graph_analysis"]
  Woods__Extractor_write_incremental_graph_analysis -->|method_call| GraphAnalyzer_new
  Woods__Extractor_write_incremental_graph_analysis -->|method_call| GraphAnalyzer
  Woods__Extractor_write_incremental_graph_analysis -->|method_call| Rails_logger
  Woods__Extractor_write_incremental_graph_analysis -->|method_call| Rails
  Woods__Extractor_safe_eager_load_["Woods::Extractor#safe_eager_load!"]
  Woods__Extractor_safe_eager_load_ -->|method_call| Rails_application
  Woods__Extractor_safe_eager_load_ -->|method_call| Rails
  Woods__Extractor_safe_eager_load_ -->|method_call| Rails_logger
  Woods__Extractor_eager_load_extraction_directories["Woods::Extractor#eager_load_extraction_directories"]
  Rails_autoloaders["Rails.autoloaders"]
  Woods__Extractor_eager_load_extraction_directories -->|method_call| Rails_autoloaders
  Woods__Extractor_eager_load_extraction_directories -->|method_call| Rails
  EXTRACTION_DIRECTORIES["EXTRACTION_DIRECTORIES"]
  Woods__Extractor_eager_load_extraction_directories -->|method_call| EXTRACTION_DIRECTORIES
  Woods__Extractor_eager_load_extraction_directories -->|method_call| Rails_root
  Woods__Extractor_eager_load_extraction_directories -->|method_call| Dir_glob
  Woods__Extractor_eager_load_extraction_directories -->|method_call| Rails_logger
  Woods__Extractor_skip_by_configuration_["Woods::Extractor#skip_by_configuration?"]
  Woods_configuration_include_framework_sources["Woods.configuration.include_framework_sources"]
  Woods__Extractor_skip_by_configuration_ -->|method_call| Woods_configuration_include_framework_sources
  Woods__Extractor_skip_by_configuration_ -->|method_call| Woods_configuration
  Woods__Extractor_skip_by_configuration_ -->|method_call| Woods
  Woods__Extractor_extract_all_sequential["Woods::Extractor#extract_all_sequential"]
  Woods__Extractor_extract_all_sequential -->|method_call| EXTRACTORS
  Woods__Extractor_extract_all_sequential -->|method_call| Rails_logger
  Woods__Extractor_extract_all_sequential -->|method_call| Rails
  Woods__Extractor_extract_all_sequential -->|method_call| Time
  Time_current["Time.current"]
  Woods__Extractor_extract_all_sequential -->|method_call| Time_current
  Woods__Extractor_extract_all_concurrent["Woods::Extractor#extract_all_concurrent"]
  Woods__Extractor_extract_all_concurrent -->|method_call| ModelNameCache
  Woods__Extractor_extract_all_concurrent -->|method_call| Mutex
  Woods__Extractor_extract_all_concurrent -->|method_call| EXTRACTORS
  Woods__Extractor_extract_all_concurrent -->|method_call| Thread
  Woods__Extractor_extract_all_concurrent -->|method_call| Rails_logger
  Woods__Extractor_extract_all_concurrent -->|method_call| Rails
  Woods__Extractor_extract_all_concurrent -->|method_call| Time
  Woods__Extractor_extract_all_concurrent -->|method_call| Time_current
  Woods__Extractor_setup_output_directory["Woods::Extractor#setup_output_directory"]
  Woods__Extractor_setup_output_directory -->|method_call| FileUtils
  Woods__Extractor_setup_output_directory -->|method_call| EXTRACTORS
  Woods__Extractor_resolve_dependents["Woods::Extractor#resolve_dependents"]
  Woods__Extractor_deduplicate_results["Woods::Extractor#deduplicate_results"]
  Woods__Extractor_deduplicate_results -->|method_call| Rails_logger
  Woods__Extractor_deduplicate_results -->|method_call| Rails
  Woods__Extractor_precompute_flows["Woods::Extractor#precompute_flows"]
  FlowPrecomputer["FlowPrecomputer"]
  Woods__Extractor_precompute_flows -->|method_call| FlowPrecomputer
  Woods__Extractor_precompute_flows -->|method_call| Rails_logger
  Woods__Extractor_precompute_flows -->|method_call| Rails
  Woods__Extractor_rewrite_flow_annotated_units["Woods::Extractor#rewrite_flow_annotated_units"]
  Woods__Extractor_rewrite_flow_annotated_units -->|method_call| AtomicFile
  Woods__Extractor_enrich_with_git_data["Woods::Extractor#enrich_with_git_data"]
  Woods__Extractor_enrich_with_git_data -->|method_call| File
  Woods__Extractor_write_unit_file["Woods::Extractor#write_unit_file"]
  Woods__Extractor_write_unit_file -->|method_call| AtomicFile
  Woods__Extractor_identical_on_disk_["Woods::Extractor#identical_on_disk?"]
  Woods__Extractor_identical_on_disk_ -->|method_call| File
  Woods__Extractor_mask_extracted_at["Woods::Extractor#mask_extracted_at"]
  Woods__Extractor_normalize_file_paths["Woods::Extractor#normalize_file_paths"]
  Woods__Extractor_normalize_file_path["Woods::Extractor#normalize_file_path"]
  Woods__Extractor_normalize_file_path -->|method_call| Rails_root
  Woods__Extractor_normalize_file_path -->|method_call| Rails
  Woods__Extractor_git_available_["Woods::Extractor#git_available?"]
  Open3["Open3"]
  Woods__Extractor_git_available_ -->|method_call| Open3
  Woods__Extractor_run_git["Woods::Extractor#run_git"]
  Woods__Extractor_run_git -->|method_call| Open3
  Woods__Extractor_batch_git_data["Woods::Extractor#batch_git_data"]
  Woods__Extractor_batch_git_data -->|method_call| Time_current
  Woods__Extractor_batch_git_data -->|method_call| Time
  Woods__Extractor_parse_git_log_output["Woods::Extractor#parse_git_log_output"]
  Woods__Extractor_parse_git_log_output -->|method_call| Hash
  Woods__Extractor_classify_change_frequency["Woods::Extractor#classify_change_frequency"]
  Woods__Extractor_build_file_metadata["Woods::Extractor#build_file_metadata"]
  Woods__Extractor_write_results["Woods::Extractor#write_results"]
  Woods__Extractor_write_results -->|method_call| AtomicFile
  Woods__Extractor_sweep_orphaned_unit_files["Woods::Extractor#sweep_orphaned_unit_files"]
  Dir___["Dir.[]"]
  Woods__Extractor_sweep_orphaned_unit_files -->|method_call| Dir___
  Woods__Extractor_sweep_orphaned_unit_files -->|method_call| FileUtils
  Woods__Extractor_sweep_orphaned_unit_files -->|method_call| Rails_logger
  Woods__Extractor_sweep_orphaned_unit_files -->|method_call| Rails
  Woods__Extractor_type_index_entries["Woods::Extractor#type_index_entries"]
  Woods__Extractor_write_dependency_graph["Woods::Extractor#write_dependency_graph"]
  Woods__Extractor_write_dependency_graph -->|method_call| AtomicFile
  Woods__Extractor_write_graph_analysis["Woods::Extractor#write_graph_analysis"]
  Woods__Extractor_write_graph_analysis -->|method_call| AtomicFile
  Woods__Extractor_write_manifest["Woods::Extractor#write_manifest"]
  GitProvenance_new["GitProvenance.new"]
  Woods__Extractor_write_manifest -->|method_call| GitProvenance_new
  GitProvenance["GitProvenance"]
  Woods__Extractor_write_manifest -->|method_call| GitProvenance
  Woods__Extractor_write_manifest -->|method_call| AtomicFile
  Woods__Extractor_persisted_counts["Woods::Extractor#persisted_counts"]
  Woods__Extractor_persisted_counts -->|method_call| Dir___
  Woods__Extractor_persisted_counts -->|method_call| JSON
  Woods__Extractor_persisted_counts -->|method_call| File
  Woods__Extractor_persisted_counts -->|method_call| Rails_logger
  Woods__Extractor_persisted_counts -->|method_call| Rails
  Woods__Extractor_capture_snapshot["Woods::Extractor#capture_snapshot"]
  Woods__Extractor_capture_snapshot -->|method_call| Woods_configuration
  Woods__Extractor_capture_snapshot -->|method_call| Woods
  Woods__Extractor_capture_snapshot -->|method_call| JSON
  Woods__Extractor_capture_snapshot -->|method_call| Rails_logger
  Woods__Extractor_capture_snapshot -->|method_call| Rails
  Woods__Extractor_build_snapshot_store["Woods::Extractor#build_snapshot_store"]
  SQLite3__Database["SQLite3::Database"]
  Woods__Extractor_build_snapshot_store -->|method_call| SQLite3__Database
  Db__Migrator_new["Db::Migrator.new"]
  Woods__Extractor_build_snapshot_store -->|method_call| Db__Migrator_new
  Db__Migrator["Db::Migrator"]
  Woods__Extractor_build_snapshot_store -->|method_call| Db__Migrator
  Temporal__SnapshotStore["Temporal::SnapshotStore"]
  Woods__Extractor_build_snapshot_store -->|method_call| Temporal__SnapshotStore
  Woods__Extractor_build_snapshot_store -->|method_call| Rails_logger
  Woods__Extractor_build_snapshot_store -->|method_call| Rails
  Temporal__JsonSnapshotStore["Temporal::JsonSnapshotStore"]
  Woods__Extractor_build_snapshot_store -->|method_call| Temporal__JsonSnapshotStore
  Woods__Extractor_write_structural_summary["Woods::Extractor#write_structural_summary"]
  Woods__Extractor_write_structural_summary -->|method_call| AtomicFile
  Woods__Extractor_regenerate_type_index["Woods::Extractor#regenerate_type_index"]
  Woods__Extractor_regenerate_type_index -->|method_call| Dir___
  Woods__Extractor_regenerate_type_index -->|method_call| File_basename
  Woods__Extractor_regenerate_type_index -->|method_call| File
  Woods__Extractor_regenerate_type_index -->|method_call| JSON
  Woods__Extractor_regenerate_type_index -->|method_call| AtomicFile
  Woods__Extractor_estimated_tokens_from["Woods::Extractor#estimated_tokens_from"]
  Woods__Extractor_estimated_tokens_from -->|method_call| TokenUtils
  Woods__Extractor_gemfile_lock_sha["Woods::Extractor#gemfile_lock_sha"]
  Woods__Extractor_gemfile_lock_sha -->|method_call| Rails_root
  Woods__Extractor_gemfile_lock_sha -->|method_call| Rails
  Digest__SHA256_file["Digest::SHA256.file"]
  Woods__Extractor_gemfile_lock_sha -->|method_call| Digest__SHA256_file
  Woods__Extractor_gemfile_lock_sha -->|method_call| Digest__SHA256
  Woods__Extractor_schema_sha["Woods::Extractor#schema_sha"]
  Woods__Extractor_schema_sha -->|method_call| Rails_root
  Woods__Extractor_schema_sha -->|method_call| Rails
  Woods__Extractor_schema_sha -->|method_call| Digest__SHA256_file
  Woods__Extractor_schema_sha -->|method_call| Digest__SHA256
  Woods__Extractor_json_serialize["Woods::Extractor#json_serialize"]
  Woods__Extractor_json_serialize -->|method_call| Woods_configuration
  Woods__Extractor_json_serialize -->|method_call| Woods
  Woods__Extractor_json_serialize -->|method_call| JSON
  Woods__Extractor_log_summary["Woods::Extractor#log_summary"]
  Woods__Extractor_log_summary -->|method_call| Rails_logger
  Woods__Extractor_log_summary -->|method_call| Rails
  Woods__Extractor_extractor_for["Woods::Extractor#extractor_for"]
  Woods__Extractor_extractor_for -->|method_call| Rails_logger
  Woods__Extractor_extractor_for -->|method_call| Rails
  Woods__Extractor_active_record_names["Woods::Extractor#active_record_names"]
  ActiveRecord__Base_descendants_filter_map["ActiveRecord::Base.descendants.filter_map"]
  Woods__Extractor_active_record_names -->|method_call| ActiveRecord__Base_descendants_filter_map
  Woods__Extractor_active_record_names -->|method_call| ActiveRecord__Base_descendants
  Woods__Extractor_active_record_names -->|method_call| ActiveRecord__Base
  Woods__Extractor_active_record_names -->|method_call| Set
  Woods__Extractor_reconcile_changed_paths["Woods::Extractor#reconcile_changed_paths"]
  PathDispatcher["PathDispatcher"]
  Woods__Extractor_reconcile_changed_paths -->|method_call| PathDispatcher
  Woods__Extractor_reconcile_changed_paths -->|method_call| Set
  Woods__Extractor_extract_with_rule["Woods::Extractor#extract_with_rule"]
  Woods__Extractor_extract_with_rule -->|method_call| Array
  Woods__Extractor_extract_with_rule -->|method_call| Rails_logger
  Woods__Extractor_extract_with_rule -->|method_call| Rails
  Woods__Extractor_prune_path_leftovers["Woods::Extractor#prune_path_leftovers"]
  Woods__Extractor_prune_path_leftovers -->|method_call| Set
  Woods__Extractor_reconcile_class_based_types["Woods::Extractor#reconcile_class_based_types"]
  Woods__Extractor_reconcile_class_based_types -->|method_call| Set
  CLASS_BASED_DISCOVERY["CLASS_BASED_DISCOVERY"]
  Woods__Extractor_reconcile_class_based_types -->|method_call| CLASS_BASED_DISCOVERY
  Woods__Extractor_reconcile_class_based_types -->|method_call| Array_flat_map
  Woods__Extractor_reconcile_class_based_types -->|method_call| Array
  Woods__Extractor_add_discovered_classes["Woods::Extractor#add_discovered_classes"]
  Woods__Extractor_add_discovered_classes -->|method_call| Set
  Woods__Extractor_add_discovered_classes -->|method_call| Rails_logger
  Woods__Extractor_add_discovered_classes -->|method_call| Rails
  Woods__Extractor_remove_stale_classes["Woods::Extractor#remove_stale_classes"]
  Woods__Extractor_remove_stale_classes -->|method_call| Set
  Woods__Extractor_remove_stale_classes -->|method_call| Rails_logger
  Woods__Extractor_remove_stale_classes -->|method_call| Rails
  Woods__Extractor_stale_class_based_units["Woods::Extractor#stale_class_based_units"]
  Woods__Extractor_rerun_whole_app_extractors["Woods::Extractor#rerun_whole_app_extractors"]
  PathDispatcher_new["PathDispatcher.new"]
  Woods__Extractor_rerun_whole_app_extractors -->|method_call| PathDispatcher_new
  Woods__Extractor_rerun_whole_app_extractors -->|method_call| PathDispatcher
  Woods__Extractor_rerun_whole_app_extractors -->|method_call| Set
  Woods__Extractor_replace_type_wholesale["Woods::Extractor#replace_type_wholesale"]
  Woods__Extractor_replace_type_wholesale -->|method_call| Set
  Array_compact["Array.compact"]
  Woods__Extractor_replace_type_wholesale -->|method_call| Array_compact
  Woods__Extractor_replace_type_wholesale -->|method_call| Array
  Woods__Extractor_replace_type_wholesale -->|method_call| Rails_logger
  Woods__Extractor_replace_type_wholesale -->|method_call| Rails
  Woods__Extractor_remove_replaced_units["Woods::Extractor#remove_replaced_units"]
  Woods__Extractor_remove_replaced_units -->|method_call| CLASS_BASED_DISCOVERY
  Woods__Extractor_remove_replaced_units -->|method_call| Rails_logger
  Woods__Extractor_remove_replaced_units -->|method_call| Rails
  Woods__Extractor_remove_replaced_units -->|method_call| Set
  EXTRACTOR_KEY_TO_TYPES_fetch["EXTRACTOR_KEY_TO_TYPES.fetch"]
  Woods__Extractor_remove_replaced_units -->|method_call| EXTRACTOR_KEY_TO_TYPES_fetch
  Woods__Extractor_prune_vanished_units["Woods::Extractor#prune_vanished_units"]
  Woods__Extractor_prune_vanished_units -->|method_call| Rails_logger
  Woods__Extractor_prune_vanished_units -->|method_call| Rails
  Woods__Extractor_sweep_candidates["Woods::Extractor#sweep_candidates"]
  Woods__Extractor_sweep_candidates -->|method_call| PathDispatcher
  Woods__Extractor_sweep_candidates -->|method_call| File
  Woods__Extractor_prune_paths["Woods::Extractor#prune_paths"]
  Woods__Extractor_prune_paths -->|method_call| File
  Woods__Extractor_convention_path_unit_["Woods::Extractor#convention_path_unit?"]
  CLASS_BASED["CLASS_BASED"]
  Woods__Extractor_convention_path_unit_ -->|method_call| CLASS_BASED
  Woods__Extractor_register_and_write["Woods::Extractor#register_and_write"]
  Woods__Extractor_register_and_write -->|method_call| Array
  Woods__Extractor_register_and_write -->|method_call| Set
  Woods__Extractor_register_and_write -->|method_call| FileUtils
  Woods__Extractor_remove_unit["Woods::Extractor#remove_unit"]
  Woods__Extractor_remove_unit -->|method_call| Rails_logger
  Woods__Extractor_remove_unit_of_type["Woods::Extractor#remove_unit_of_type"]
  TYPE_TO_EXTRACTOR_KEY["TYPE_TO_EXTRACTOR_KEY"]
  Woods__Extractor_remove_unit_of_type -->|method_call| TYPE_TO_EXTRACTOR_KEY
  Woods__Extractor_remove_unit_of_type -->|method_call| FileUtils
  Woods__Extractor_mark_dependents_dirty["Woods::Extractor#mark_dependents_dirty"]
  Woods__Extractor_mark_dependents_dirty -->|method_call| Set
  Woods__Extractor_finalize_incremental_unit_json["Woods::Extractor#finalize_incremental_unit_json"]
  Woods__Extractor_finalize_incremental_unit_json -->|method_call| Set
  Woods__Extractor_rewrite_unit_json["Woods::Extractor#rewrite_unit_json"]
  Woods__Extractor_rewrite_unit_json_of_type["Woods::Extractor#rewrite_unit_json_of_type"]
  Woods__Extractor_rewrite_unit_json_of_type -->|method_call| TYPE_TO_EXTRACTOR_KEY
  Woods__Extractor_rewrite_unit_json_of_type -->|method_call| File
  Woods__Extractor_rewrite_unit_json_of_type -->|method_call| JSON
  JSON_generate["JSON.generate"]
  Woods__Extractor_rewrite_unit_json_of_type -->|method_call| JSON_generate
  Woods__Extractor_rewrite_unit_json_of_type -->|method_call| AtomicFile
  Woods__Extractor_rewrite_unit_json_of_type -->|method_call| Rails_logger
  Woods__Extractor_rewrite_unit_json_of_type -->|method_call| Rails
  Woods__Extractor_git_for_type["Woods::Extractor#git_for_type"]
  Woods__Extractor_incremental_git_data["Woods::Extractor#incremental_git_data"]
  Woods__Extractor_incremental_git_data -->|method_call| File
  Woods__Extractor_incremental_git_data -->|method_call| Rails_logger
  Woods__Extractor_incremental_git_data -->|method_call| Rails
  Woods__Extractor_re_extract_unit["Woods::Extractor#re_extract_unit"]
  Woods__Extractor_re_extract_unit -->|method_call| Rails_logger
  Woods__Extractor_re_extract_unit -->|method_call| Rails
  Woods__Extractor_re_extract_unit_of_type["Woods::Extractor#re_extract_unit_of_type"]
  Woods__Extractor_re_extract_unit_of_type -->|method_call| File
  Woods__Extractor_re_extract_unit_of_type -->|method_call| TYPE_TO_EXTRACTOR_KEY
  Woods__Extractor_re_extract_unit_of_type -->|method_call| Array
  Woods__Extractor_re_extracted_units["Woods::Extractor#re_extracted_units"]
  Woods__Extractor_re_extracted_units -->|method_call| CLASS_BASED
  FILE_BASED["FILE_BASED"]
  Woods__Extractor_re_extracted_units -->|method_call| FILE_BASED
  GRAPHQL_TYPES["GRAPHQL_TYPES"]
  Woods__Extractor_re_extracted_units -->|method_call| GRAPHQL_TYPES
  Woods__Extractor_constant_for_identifier["Woods::Extractor#constant_for_identifier"]
  Woods__Extractor_extract_file_based_unit["Woods::Extractor#extract_file_based_unit"]
  Woods__Extractors["Woods::Extractors"]
  Woods__Extractors__ActionCableExtractor["Woods::Extractors::ActionCableExtractor"]
  SharedUtilityMethods["SharedUtilityMethods"]
  Woods__Extractors__ActionCableExtractor -->|include| SharedUtilityMethods
  SharedDependencyScanner["SharedDependencyScanner"]
  Woods__Extractors__ActionCableExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__ActionCableExtractor_initialize["Woods::Extractors::ActionCableExtractor#initialize"]
  Woods__Extractors__ActionCableExtractor_extract_all["Woods::Extractors::ActionCableExtractor#extract_all"]
  Woods__Extractors__ActionCableExtractor_discoverable_classes["Woods::Extractors::ActionCableExtractor#discoverable_classes"]
  Woods__Extractors__ActionCableExtractor_extract_channel["Woods::Extractors::ActionCableExtractor#extract_channel"]
  Woods__Extractors__ActionCableExtractor_extract_channel -->|method_call| ExtractedUnit
  Woods__Extractors__ActionCableExtractor_action_cable_available_["Woods::Extractors::ActionCableExtractor#action_cable_available?"]
  Woods__Extractors__ActionCableExtractor_channel_descendants["Woods::Extractors::ActionCableExtractor#channel_descendants"]
  ActionCable__Channel__Base_descendants["ActionCable::Channel::Base.descendants"]
  Woods__Extractors__ActionCableExtractor_channel_descendants -->|method_call| ActionCable__Channel__Base_descendants
  Woods__Extractors__ActionCableExtractor_source_file_for["Woods::Extractors::ActionCableExtractor#source_file_for"]
  Woods__Extractors__ActionCableExtractor_source_file_for -->|method_call| Rails
  Rails_root_join["Rails.root.join"]
  Woods__Extractors__ActionCableExtractor_source_file_for -->|method_call| Rails_root_join
  Woods__Extractors__ActionCableExtractor_source_file_for -->|method_call| Rails_root
  Woods__Extractors__ActionCableExtractor_source_file_for -->|method_call| File
  Woods__Extractors__ActionCableExtractor_read_source["Woods::Extractors::ActionCableExtractor#read_source"]
  Woods__Extractors__ActionCableExtractor_read_source -->|method_call| File
  Woods__Extractors__ActionCableExtractor_build_metadata["Woods::Extractors::ActionCableExtractor#build_metadata"]
  Woods__Extractors__ActionCableExtractor_detect_stream_names["Woods::Extractors::ActionCableExtractor#detect_stream_names"]
  Woods__Extractors__ActionCableExtractor_detect_actions["Woods::Extractors::ActionCableExtractor#detect_actions"]
  Woods__Extractors__ActionCableExtractor_detect_broadcasts["Woods::Extractors::ActionCableExtractor#detect_broadcasts"]
  Woods__Extractors__ActionCableExtractor_count_loc["Woods::Extractors::ActionCableExtractor#count_loc"]
  Woods__Extractors__ActionCableExtractor_log_extraction_error["Woods::Extractors::ActionCableExtractor#log_extraction_error"]
  Woods__Extractors__ActionCableExtractor_log_extraction_error -->|method_call| Rails
  Woods__Extractors__ActionCableExtractor_log_extraction_error -->|method_call| Rails_logger
  Woods__Extractors__AstSourceExtraction["Woods::Extractors::AstSourceExtraction"]
  Woods__Extractors__AstSourceExtraction_extract_action_source["Woods::Extractors::AstSourceExtraction#extract_action_source"]
  Woods__Extractors__AstSourceExtraction_extract_action_source -->|method_call| File
  Ast__MethodExtractor_new["Ast::MethodExtractor.new"]
  Woods__Extractors__AstSourceExtraction_extract_action_source -->|method_call| Ast__MethodExtractor_new
  Ast__MethodExtractor["Ast::MethodExtractor"]
  Woods__Extractors__AstSourceExtraction_extract_action_source -->|method_call| Ast__MethodExtractor
  Woods__Extractors__AstSourceExtraction_extract_action_source -->|method_call| Rails_logger
  Woods__Extractors__AstSourceExtraction_extract_action_source -->|method_call| Rails
  Woods__Extractors__BehavioralProfile["Woods::Extractors::BehavioralProfile"]
  Woods__Extractors__BehavioralProfile_extract["Woods::Extractors::BehavioralProfile#extract"]
  Woods__Extractors__BehavioralProfile_extract -->|method_call| Rails_application
  Woods__Extractors__BehavioralProfile_extract -->|method_call| Rails
  Woods__Extractors__BehavioralProfile_extract -->|method_call| Rails_logger
  Woods__Extractors__BehavioralProfile_extract_database["Woods::Extractors::BehavioralProfile#extract_database"]
  Woods__Extractors__BehavioralProfile_extract_database -->|method_call| ActiveRecord__Base
  Woods__Extractors__BehavioralProfile_extract_database -->|method_call| Rails_logger
  Woods__Extractors__BehavioralProfile_extract_database -->|method_call| Rails
  Woods__Extractors__BehavioralProfile_extract_frameworks["Woods::Extractors::BehavioralProfile#extract_frameworks"]
  FRAMEWORK_CHECKS["FRAMEWORK_CHECKS"]
  Woods__Extractors__BehavioralProfile_extract_frameworks -->|method_call| FRAMEWORK_CHECKS
  Woods__Extractors__BehavioralProfile_extract_frameworks -->|method_call| Object
  Woods__Extractors__BehavioralProfile_extract_frameworks -->|method_call| Rails_logger
  Woods__Extractors__BehavioralProfile_extract_frameworks -->|method_call| Rails
  Woods__Extractors__BehavioralProfile_extract_behavior_flags["Woods::Extractors::BehavioralProfile#extract_behavior_flags"]
  Woods__Extractors__BehavioralProfile_extract_behavior_flags -->|method_call| Rails_logger
  Woods__Extractors__BehavioralProfile_extract_behavior_flags -->|method_call| Rails
  Woods__Extractors__BehavioralProfile_extract_background["Woods::Extractors::BehavioralProfile#extract_background"]
  Woods__Extractors__BehavioralProfile_extract_background -->|method_call| Rails_logger
  Woods__Extractors__BehavioralProfile_extract_background -->|method_call| Rails
  Woods__Extractors__BehavioralProfile_extract_caching["Woods::Extractors::BehavioralProfile#extract_caching"]
  Woods__Extractors__BehavioralProfile_extract_caching -->|method_call| Rails_logger
  Woods__Extractors__BehavioralProfile_extract_caching -->|method_call| Rails
  Woods__Extractors__BehavioralProfile_extract_email["Woods::Extractors::BehavioralProfile#extract_email"]
  Woods__Extractors__BehavioralProfile_extract_email -->|method_call| Rails_logger
  Woods__Extractors__BehavioralProfile_extract_email -->|method_call| Rails
  Woods__Extractors__BehavioralProfile_build_unit["Woods::Extractors::BehavioralProfile#build_unit"]
  Woods__Extractors__BehavioralProfile_build_unit -->|method_call| ExtractedUnit
  Woods__Extractors__BehavioralProfile_build_narrative["Woods::Extractors::BehavioralProfile#build_narrative"]
  Woods__Extractors__BehavioralProfile_build_dependencies["Woods::Extractors::BehavioralProfile#build_dependencies"]
  Woods__Extractors__BehavioralProfile_build_dependencies -->|method_call| FRAMEWORK_CHECKS
  Woods__Extractors__BehavioralProfile_safe_read["Woods::Extractors::BehavioralProfile#safe_read"]
  Woods__Extractors__CachingExtractor["Woods::Extractors::CachingExtractor"]
  Woods__Extractors__CachingExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__CachingExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__CachingExtractor_initialize["Woods::Extractors::CachingExtractor#initialize"]
  Woods__Extractors__CachingExtractor_initialize -->|method_call| Rails
  Woods__Extractors__CachingExtractor_extract_all["Woods::Extractors::CachingExtractor#extract_all"]
  SCAN_PATTERNS["SCAN_PATTERNS"]
  Woods__Extractors__CachingExtractor_extract_all -->|method_call| SCAN_PATTERNS
  Woods__Extractors__CachingExtractor_extract_all -->|method_call| Dir___
  Woods__Extractors__CachingExtractor_extract_caching_file["Woods::Extractors::CachingExtractor#extract_caching_file"]
  Woods__Extractors__CachingExtractor_extract_caching_file -->|method_call| File
  Woods__Extractors__CachingExtractor_extract_caching_file -->|method_call| ExtractedUnit
  Woods__Extractors__CachingExtractor_extract_caching_file -->|method_call| Rails_logger
  Woods__Extractors__CachingExtractor_extract_caching_file -->|method_call| Rails
  Woods__Extractors__CachingExtractor_cache_usage_["Woods::Extractors::CachingExtractor#cache_usage?"]
  CACHE_PATTERNS_values["CACHE_PATTERNS.values"]
  Woods__Extractors__CachingExtractor_cache_usage_ -->|method_call| CACHE_PATTERNS_values
  Woods__Extractors__CachingExtractor_annotate_source["Woods::Extractors::CachingExtractor#annotate_source"]
  Woods__Extractors__CachingExtractor_extract_metadata["Woods::Extractors::CachingExtractor#extract_metadata"]
  Woods__Extractors__CachingExtractor_extract_cache_calls["Woods::Extractors::CachingExtractor#extract_cache_calls"]
  CACHE_PATTERNS["CACHE_PATTERNS"]
  Woods__Extractors__CachingExtractor_extract_cache_calls -->|method_call| CACHE_PATTERNS
  Woods__Extractors__CachingExtractor_each_occurrence["Woods::Extractors::CachingExtractor#each_occurrence"]
  Woods__Extractors__CachingExtractor_call_argument_text["Woods::Extractors::CachingExtractor#call_argument_text"]
  Woods__Extractors__CachingExtractor_extract_key_pattern["Woods::Extractors::CachingExtractor#extract_key_pattern"]
  Woods__Extractors__CachingExtractor_extract_ttl["Woods::Extractors::CachingExtractor#extract_ttl"]
  Woods__Extractors__CachingExtractor_infer_cache_strategy["Woods::Extractors::CachingExtractor#infer_cache_strategy"]
  Woods__Extractors__CachingExtractor_infer_file_type["Woods::Extractors::CachingExtractor#infer_file_type"]
  Woods__Extractors__CachingExtractor_relative_path["Woods::Extractors::CachingExtractor#relative_path"]
  Woods__Extractors__CachingExtractor_extract_dependencies["Woods::Extractors::CachingExtractor#extract_dependencies"]
  Woods__Extractors__CallbackAnalyzer["Woods::Extractors::CallbackAnalyzer"]
  Woods__Extractors__CallbackAnalyzer_initialize["Woods::Extractors::CallbackAnalyzer#initialize"]
  Ast__Parser["Ast::Parser"]
  Woods__Extractors__CallbackAnalyzer_initialize -->|method_call| Ast__Parser
  FlowAnalysis__OperationExtractor["FlowAnalysis::OperationExtractor"]
  Woods__Extractors__CallbackAnalyzer_initialize -->|method_call| FlowAnalysis__OperationExtractor
  Woods__Extractors__CallbackAnalyzer_analyze["Woods::Extractors::CallbackAnalyzer#analyze"]
  Woods__Extractors__CallbackAnalyzer_safe_parse["Woods::Extractors::CallbackAnalyzer#safe_parse"]
  Woods__Extractors__CallbackAnalyzer_find_method_node["Woods::Extractors::CallbackAnalyzer#find_method_node"]
  Woods__Extractors__CallbackAnalyzer_method_source_from_node["Woods::Extractors::CallbackAnalyzer#method_source_from_node"]
  Woods__Extractors__CallbackAnalyzer_valid_method_name_["Woods::Extractors::CallbackAnalyzer#valid_method_name?"]
  Woods__Extractors__CallbackAnalyzer_detect_columns_written["Woods::Extractors::CallbackAnalyzer#detect_columns_written"]
  Woods__Extractors__CallbackAnalyzer_detect_columns_written -->|method_call| Set
  SINGLE_COLUMN_WRITER_PATTERNS["SINGLE_COLUMN_WRITER_PATTERNS"]
  Woods__Extractors__CallbackAnalyzer_detect_columns_written -->|method_call| SINGLE_COLUMN_WRITER_PATTERNS
  MULTI_COLUMN_WRITER_PATTERNS["MULTI_COLUMN_WRITER_PATTERNS"]
  Woods__Extractors__CallbackAnalyzer_detect_columns_written -->|method_call| MULTI_COLUMN_WRITER_PATTERNS
  Woods__Extractors__CallbackAnalyzer_detect_jobs_enqueued["Woods::Extractors::CallbackAnalyzer#detect_jobs_enqueued"]
  Woods__Extractors__CallbackAnalyzer_detect_services_called["Woods::Extractors::CallbackAnalyzer#detect_services_called"]
  Woods__Extractors__CallbackAnalyzer_detect_mailers_triggered["Woods::Extractors::CallbackAnalyzer#detect_mailers_triggered"]
  Woods__Extractors__CallbackAnalyzer_detect_database_reads["Woods::Extractors::CallbackAnalyzer#detect_database_reads"]
  DB_READ_PATTERNS["DB_READ_PATTERNS"]
  Woods__Extractors__CallbackAnalyzer_detect_database_reads -->|method_call| DB_READ_PATTERNS
  Woods__Extractors__CallbackAnalyzer_extract_operations["Woods::Extractors::CallbackAnalyzer#extract_operations"]
  Woods__Extractors__CallbackAnalyzer_empty_side_effects["Woods::Extractors::CallbackAnalyzer#empty_side_effects"]
  Woods__Extractors__ConcernExtractor["Woods::Extractors::ConcernExtractor"]
  Woods__Extractors__ConcernExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__ConcernExtractor -->|include| SharedDependencyScanner
  SourceNesting["SourceNesting"]
  Woods__Extractors__ConcernExtractor -->|include| SourceNesting
  Woods__Extractors__ConcernExtractor_initialize["Woods::Extractors::ConcernExtractor#initialize"]
  Dir____map["Dir.[].map"]
  Woods__Extractors__ConcernExtractor_initialize -->|method_call| Dir____map
  Woods__Extractors__ConcernExtractor_initialize -->|method_call| Dir___
  Woods__Extractors__ConcernExtractor_initialize -->|method_call| Pathname
  CONCERN_DIRECTORIES_map["CONCERN_DIRECTORIES.map"]
  Woods__Extractors__ConcernExtractor_initialize -->|method_call| CONCERN_DIRECTORIES_map
  CONCERN_DIRECTORIES["CONCERN_DIRECTORIES"]
  Woods__Extractors__ConcernExtractor_initialize -->|method_call| CONCERN_DIRECTORIES
  Woods__Extractors__ConcernExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__ConcernExtractor_initialize -->|method_call| Rails
  Woods__Extractors__ConcernExtractor_extract_all["Woods::Extractors::ConcernExtractor#extract_all"]
  Woods__Extractors__ConcernExtractor_extract_concern_file["Woods::Extractors::ConcernExtractor#extract_concern_file"]
  Woods__Extractors__ConcernExtractor_extract_concern_file -->|method_call| File
  Woods__Extractors__ConcernExtractor_extract_concern_file -->|method_call| ExtractedUnit
  Woods__Extractors__ConcernExtractor_extract_concern_file -->|method_call| Rails_logger
  Woods__Extractors__ConcernExtractor_extract_concern_file -->|method_call| Rails
  Woods__Extractors__ConcernExtractor_extract_module_name["Woods::Extractors::ConcernExtractor#extract_module_name"]
  Woods__Extractors__ConcernExtractor_concern_module_["Woods::Extractors::ConcernExtractor#concern_module?"]
  Woods__Extractors__ConcernExtractor_annotate_source["Woods::Extractors::ConcernExtractor#annotate_source"]
  Woods__Extractors__ConcernExtractor_extract_metadata["Woods::Extractors::ConcernExtractor#extract_metadata"]
  Woods__Extractors__ConcernExtractor_detect_concern_type["Woods::Extractors::ConcernExtractor#detect_concern_type"]
  Woods__Extractors__ConcernExtractor_detect_concern_scope["Woods::Extractors::ConcernExtractor#detect_concern_scope"]
  Woods__Extractors__ConcernExtractor_extract_instance_method_names["Woods::Extractors::ConcernExtractor#extract_instance_method_names"]
  Woods__Extractors__ConcernExtractor_detect_included_modules["Woods::Extractors::ConcernExtractor#detect_included_modules"]
  Woods__Extractors__ConcernExtractor_detect_includes["Woods::Extractors::ConcernExtractor#detect_includes"]
  Woods__Extractors__ConcernExtractor_detect_extends["Woods::Extractors::ConcernExtractor#detect_extends"]
  Woods__Extractors__ConcernExtractor_detect_callbacks["Woods::Extractors::ConcernExtractor#detect_callbacks"]
  Woods__Extractors__ConcernExtractor_detect_scopes["Woods::Extractors::ConcernExtractor#detect_scopes"]
  Woods__Extractors__ConcernExtractor_detect_validations["Woods::Extractors::ConcernExtractor#detect_validations"]
  Woods__Extractors__ConcernExtractor_extract_dependencies["Woods::Extractors::ConcernExtractor#extract_dependencies"]
  Woods__Extractors__ConfigurationExtractor["Woods::Extractors::ConfigurationExtractor"]
  Woods__Extractors__ConfigurationExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__ConfigurationExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__ConfigurationExtractor_initialize["Woods::Extractors::ConfigurationExtractor#initialize"]
  CONFIG_DIRECTORIES_map["CONFIG_DIRECTORIES.map"]
  Woods__Extractors__ConfigurationExtractor_initialize -->|method_call| CONFIG_DIRECTORIES_map
  CONFIG_DIRECTORIES["CONFIG_DIRECTORIES"]
  Woods__Extractors__ConfigurationExtractor_initialize -->|method_call| CONFIG_DIRECTORIES
  Woods__Extractors__ConfigurationExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__ConfigurationExtractor_initialize -->|method_call| Rails
  Woods__Extractors__ConfigurationExtractor_extract_all["Woods::Extractors::ConfigurationExtractor#extract_all"]
  BehavioralProfile_new["BehavioralProfile.new"]
  Woods__Extractors__ConfigurationExtractor_extract_all -->|method_call| BehavioralProfile_new
  BehavioralProfile["BehavioralProfile"]
  Woods__Extractors__ConfigurationExtractor_extract_all -->|method_call| BehavioralProfile
  Woods__Extractors__ConfigurationExtractor_extract_all -->|method_call| Rails_logger
  Woods__Extractors__ConfigurationExtractor_extract_all -->|method_call| Rails
  Woods__Extractors__ConfigurationExtractor_extract_configuration_file["Woods::Extractors::ConfigurationExtractor#extract_configuration_file"]
  Woods__Extractors__ConfigurationExtractor_extract_configuration_file -->|method_call| File
  Woods__Extractors__ConfigurationExtractor_extract_configuration_file -->|method_call| ExtractedUnit
  Woods__Extractors__ConfigurationExtractor_extract_configuration_file -->|method_call| Rails_logger
  Woods__Extractors__ConfigurationExtractor_extract_configuration_file -->|method_call| Rails
  Woods__Extractors__ConfigurationExtractor_build_identifier["Woods::Extractors::ConfigurationExtractor#build_identifier"]
  Woods__Extractors__ConfigurationExtractor_detect_config_type["Woods::Extractors::ConfigurationExtractor#detect_config_type"]
  Woods__Extractors__ConfigurationExtractor_annotate_source["Woods::Extractors::ConfigurationExtractor#annotate_source"]
  Woods__Extractors__ConfigurationExtractor_extract_metadata["Woods::Extractors::ConfigurationExtractor#extract_metadata"]
  Woods__Extractors__ConfigurationExtractor_detect_gem_references["Woods::Extractors::ConfigurationExtractor#detect_gem_references"]
  Woods__Extractors__ConfigurationExtractor_detect_config_settings["Woods::Extractors::ConfigurationExtractor#detect_config_settings"]
  Woods__Extractors__ConfigurationExtractor_detect_rails_config_blocks["Woods::Extractors::ConfigurationExtractor#detect_rails_config_blocks"]
  Woods__Extractors__ConfigurationExtractor_generic_config_name_["Woods::Extractors::ConfigurationExtractor#generic_config_name?"]
  Woods__Extractors__ConfigurationExtractor_extract_dependencies["Woods::Extractors::ConfigurationExtractor#extract_dependencies"]
  Woods__Extractors__ControllerExtractor["Woods::Extractors::ControllerExtractor"]
  AstSourceExtraction["AstSourceExtraction"]
  Woods__Extractors__ControllerExtractor -->|include| AstSourceExtraction
  Woods__Extractors__ControllerExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__ControllerExtractor -->|include| SharedDependencyScanner
  RouteHelperResolver["RouteHelperResolver"]
  Woods__Extractors__ControllerExtractor -->|include| RouteHelperResolver
  Woods__Extractors__ControllerExtractor_initialize["Woods::Extractors::ControllerExtractor#initialize"]
  Woods__Extractors__ControllerExtractor_extract_all["Woods::Extractors::ControllerExtractor#extract_all"]
  Woods__Extractors__ControllerExtractor_discoverable_classes["Woods::Extractors::ControllerExtractor#discoverable_classes"]
  Woods__Extractors__ControllerExtractor_extract_controller["Woods::Extractors::ControllerExtractor#extract_controller"]
  Woods__Extractors__ControllerExtractor_extract_controller -->|method_call| ExtractedUnit
  Woods__Extractors__ControllerExtractor_extract_controller -->|method_call| File
  Woods__Extractors__ControllerExtractor_extract_controller -->|method_call| Rails_logger
  Woods__Extractors__ControllerExtractor_extract_controller -->|method_call| Rails
  Woods__Extractors__ControllerExtractor_build_routes_map["Woods::Extractors::ControllerExtractor#build_routes_map"]
  Rails_application_routes_routes["Rails.application.routes.routes"]
  Woods__Extractors__ControllerExtractor_build_routes_map -->|method_call| Rails_application_routes_routes
  Woods__Extractors__ControllerExtractor_extract_verb["Woods::Extractors::ControllerExtractor#extract_verb"]
  Woods__Extractors__ControllerExtractor_app_defined_controller_["Woods::Extractors::ControllerExtractor#app_defined_controller?"]
  Woods__Extractors__ControllerExtractor_app_defined_controller_ -->|method_call| File
  Woods__Extractors__ControllerExtractor_source_file_for["Woods::Extractors::ControllerExtractor#source_file_for"]
  Woods__Extractors__ControllerExtractor_source_file_for -->|method_call| Rails_root_join
  Woods__Extractors__ControllerExtractor_source_file_for -->|method_call| Rails_root
  Woods__Extractors__ControllerExtractor_source_file_for -->|method_call| Rails
  Woods__Extractors__ControllerExtractor_source_file_for -->|method_call| File
  Woods__Extractors__ControllerExtractor_build_composite_source["Woods::Extractors::ControllerExtractor#build_composite_source"]
  Woods__Extractors__ControllerExtractor_build_routes_comment["Woods::Extractors::ControllerExtractor#build_routes_comment"]
  Woods__Extractors__ControllerExtractor_build_filters_comment["Woods::Extractors::ControllerExtractor#build_filters_comment"]
  Woods__Extractors__ControllerExtractor_extract_filter_chain["Woods::Extractors::ControllerExtractor#extract_filter_chain"]
  Woods__Extractors__ControllerExtractor_detect_included_concerns["Woods::Extractors::ControllerExtractor#detect_included_concerns"]
  Woods__Extractors__ControllerExtractor_app_concern_module_["Woods::Extractors::ControllerExtractor#app_concern_module?"]
  Woods__Extractors__ControllerExtractor_compute_app_concern_module["Woods::Extractors::ControllerExtractor#compute_app_concern_module"]
  Woods__Extractors__ControllerExtractor_module_source_path["Woods::Extractors::ControllerExtractor#module_source_path"]
  Woods__Extractors__ControllerExtractor_module_source_path -->|method_call| Object
  Object_const_source_location["Object.const_source_location"]
  Woods__Extractors__ControllerExtractor_module_source_path -->|method_call| Object_const_source_location
  Woods__Extractors__ControllerExtractor_activesupport_concern_["Woods::Extractors::ControllerExtractor#activesupport_concern?"]
  Woods__Extractors__ControllerExtractor_concerns_directory_path_["Woods::Extractors::ControllerExtractor#concerns_directory_path?"]
  Woods__Extractors__ControllerExtractor_build_controller_source_with_concerns["Woods::Extractors::ControllerExtractor#build_controller_source_with_concerns"]
  Woods__Extractors__ControllerExtractor_build_controller_source_with_concerns -->|method_call| File
  Woods__Extractors__ControllerExtractor_resolved_concern_sources["Woods::Extractors::ControllerExtractor#resolved_concern_sources"]
  Woods__Extractors__ControllerExtractor_concern_source["Woods::Extractors::ControllerExtractor#concern_source"]
  Woods__Extractors__ControllerExtractor_concern_source -->|method_call| File
  Woods__Extractors__ControllerExtractor_build_concern_block["Woods::Extractors::ControllerExtractor#build_concern_block"]
  Woods__Extractors__ControllerExtractor_insert_concern_block["Woods::Extractors::ControllerExtractor#insert_concern_block"]
  Woods__Extractors__ControllerExtractor_class_declaration_pattern["Woods::Extractors::ControllerExtractor#class_declaration_pattern"]
  Woods__Extractors__ControllerExtractor_class_declaration_pattern -->|method_call| Regexp
  Woods__Extractors__ControllerExtractor_extract_metadata["Woods::Extractors::ControllerExtractor#extract_metadata"]
  Woods__Extractors__ControllerExtractor_extract_included_concerns["Woods::Extractors::ControllerExtractor#extract_included_concerns"]
  Woods__Extractors__ControllerExtractor_extract_respond_formats["Woods::Extractors::ControllerExtractor#extract_respond_formats"]
  Woods__Extractors__ControllerExtractor_extract_respond_formats -->|method_call| File
  Woods__Extractors__ControllerExtractor_extract_permitted_params["Woods::Extractors::ControllerExtractor#extract_permitted_params"]
  Woods__Extractors__ControllerExtractor_extract_permitted_params -->|method_call| File
  Woods__Extractors__ControllerExtractor_extract_dependencies["Woods::Extractors::ControllerExtractor#extract_dependencies"]
  Woods__Extractors__ControllerExtractor_extract_dependencies -->|method_call| File
  Woods__Extractors__ControllerExtractor_build_action_chunks["Woods::Extractors::ControllerExtractor#build_action_chunks"]
  Woods__Extractors__ControllerExtractor_applicable_filters["Woods::Extractors::ControllerExtractor#applicable_filters"]
  Woods__Extractors__ControllerExtractor_callback_applies_to_action_["Woods::Extractors::ControllerExtractor#callback_applies_to_action?"]
  Woods__Extractors__DatabaseViewExtractor["Woods::Extractors::DatabaseViewExtractor"]
  Woods__Extractors__DatabaseViewExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__DatabaseViewExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__DatabaseViewExtractor_initialize["Woods::Extractors::DatabaseViewExtractor#initialize"]
  Woods__Extractors__DatabaseViewExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__DatabaseViewExtractor_initialize -->|method_call| Rails
  Woods__Extractors__DatabaseViewExtractor_extract_all["Woods::Extractors::DatabaseViewExtractor#extract_all"]
  Woods__Extractors__DatabaseViewExtractor_extract_view_file["Woods::Extractors::DatabaseViewExtractor#extract_view_file"]
  Woods__Extractors__DatabaseViewExtractor_extract_view_file -->|method_call| File
  Woods__Extractors__DatabaseViewExtractor_extract_view_file -->|method_call| ExtractedUnit
  Woods__Extractors__DatabaseViewExtractor_extract_view_file -->|method_call| Rails_logger
  Woods__Extractors__DatabaseViewExtractor_extract_view_file -->|method_call| Rails
  Woods__Extractors__DatabaseViewExtractor_latest_view_files["Woods::Extractors::DatabaseViewExtractor#latest_view_files"]
  Woods__Extractors__DatabaseViewExtractor_latest_view_files -->|method_call| Dir___
  Woods__Extractors__DatabaseViewExtractor_latest_view_files -->|method_call| File_basename
  Woods__Extractors__DatabaseViewExtractor_latest_view_files -->|method_call| File
  Woods__Extractors__DatabaseViewExtractor_extract_view_name["Woods::Extractors::DatabaseViewExtractor#extract_view_name"]
  Woods__Extractors__DatabaseViewExtractor_extract_view_name -->|method_call| File
  Woods__Extractors__DatabaseViewExtractor_extract_version["Woods::Extractors::DatabaseViewExtractor#extract_version"]
  Woods__Extractors__DatabaseViewExtractor_extract_version -->|method_call| File
  Woods__Extractors__DatabaseViewExtractor_annotate_source["Woods::Extractors::DatabaseViewExtractor#annotate_source"]
  Woods__Extractors__DatabaseViewExtractor_extract_metadata["Woods::Extractors::DatabaseViewExtractor#extract_metadata"]
  Woods__Extractors__DatabaseViewExtractor_materialized_view_["Woods::Extractors::DatabaseViewExtractor#materialized_view?"]
  Woods__Extractors__DatabaseViewExtractor_extract_referenced_tables["Woods::Extractors::DatabaseViewExtractor#extract_referenced_tables"]
  Woods__Extractors__DatabaseViewExtractor_extract_selected_columns["Woods::Extractors::DatabaseViewExtractor#extract_selected_columns"]
  Woods__Extractors__DatabaseViewExtractor_sql_keyword_["Woods::Extractors::DatabaseViewExtractor#sql_keyword?"]
  SQL_KEYWORDS["SQL_KEYWORDS"]
  Woods__Extractors__DatabaseViewExtractor_sql_keyword_ -->|method_call| SQL_KEYWORDS
  Woods__Extractors__DatabaseViewExtractor_extract_dependencies["Woods::Extractors::DatabaseViewExtractor#extract_dependencies"]
  INTERNAL_TABLES["INTERNAL_TABLES"]
  Woods__Extractors__DatabaseViewExtractor_extract_dependencies -->|method_call| INTERNAL_TABLES
  Woods__Extractors__DecoratorExtractor["Woods::Extractors::DecoratorExtractor"]
  Woods__Extractors__DecoratorExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__DecoratorExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__DecoratorExtractor_initialize["Woods::Extractors::DecoratorExtractor#initialize"]
  DECORATOR_DIRECTORIES_map["DECORATOR_DIRECTORIES.map"]
  Woods__Extractors__DecoratorExtractor_initialize -->|method_call| DECORATOR_DIRECTORIES_map
  DECORATOR_DIRECTORIES["DECORATOR_DIRECTORIES"]
  Woods__Extractors__DecoratorExtractor_initialize -->|method_call| DECORATOR_DIRECTORIES
  Woods__Extractors__DecoratorExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__DecoratorExtractor_initialize -->|method_call| Rails
  Woods__Extractors__DecoratorExtractor_extract_all["Woods::Extractors::DecoratorExtractor#extract_all"]
  Woods__Extractors__DecoratorExtractor_extract_decorator_file["Woods::Extractors::DecoratorExtractor#extract_decorator_file"]
  Woods__Extractors__DecoratorExtractor_extract_decorator_file -->|method_call| File
  Woods__Extractors__DecoratorExtractor_extract_decorator_file -->|method_call| ExtractedUnit
  Woods__Extractors__DecoratorExtractor_extract_decorator_file -->|method_call| Rails_logger
  Woods__Extractors__DecoratorExtractor_extract_decorator_file -->|method_call| Rails
  Woods__Extractors__DecoratorExtractor_extract_class_name["Woods::Extractors::DecoratorExtractor#extract_class_name"]
  Woods__Extractors__DecoratorExtractor_annotate_source["Woods::Extractors::DecoratorExtractor#annotate_source"]
  Woods__Extractors__DecoratorExtractor_extract_metadata["Woods::Extractors::DecoratorExtractor#extract_metadata"]
  Woods__Extractors__DecoratorExtractor_infer_decorator_type["Woods::Extractors::DecoratorExtractor#infer_decorator_type"]
  DIRECTORY_TYPE_MAP["DIRECTORY_TYPE_MAP"]
  Woods__Extractors__DecoratorExtractor_infer_decorator_type -->|method_call| DIRECTORY_TYPE_MAP
  Woods__Extractors__DecoratorExtractor_infer_decorated_model["Woods::Extractors::DecoratorExtractor#infer_decorated_model"]
  DECORATOR_SUFFIXES["DECORATOR_SUFFIXES"]
  Woods__Extractors__DecoratorExtractor_infer_decorated_model -->|method_call| DECORATOR_SUFFIXES
  Woods__Extractors__DecoratorExtractor_draper_["Woods::Extractors::DecoratorExtractor#draper?"]
  Woods__Extractors__DecoratorExtractor_extract_delegated_methods["Woods::Extractors::DecoratorExtractor#extract_delegated_methods"]
  Woods__Extractors__DecoratorExtractor_detect_entry_points["Woods::Extractors::DecoratorExtractor#detect_entry_points"]
  Woods__Extractors__DecoratorExtractor_extract_dependencies["Woods::Extractors::DecoratorExtractor#extract_dependencies"]
  Woods__Extractors__EngineExtractor["Woods::Extractors::EngineExtractor"]
  Woods__Extractors__EngineExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__EngineExtractor_initialize["Woods::Extractors::EngineExtractor#initialize"]
  Woods__Extractors__EngineExtractor_extract_all["Woods::Extractors::EngineExtractor#extract_all"]
  Woods__Extractors__EngineExtractor_engines_available_["Woods::Extractors::EngineExtractor#engines_available?"]
  Woods__Extractors__EngineExtractor_engines_available_ -->|method_call| Rails
  Woods__Extractors__EngineExtractor_engines_available_ -->|method_call| Rails_application
  Woods__Extractors__EngineExtractor_engine_subclasses["Woods::Extractors::EngineExtractor#engine_subclasses"]
  Rails__Engine["Rails::Engine"]
  Woods__Extractors__EngineExtractor_engine_subclasses -->|method_call| Rails__Engine
  ObjectSpace_each_object["ObjectSpace.each_object"]
  Woods__Extractors__EngineExtractor_engine_subclasses -->|method_call| ObjectSpace_each_object
  Woods__Extractors__EngineExtractor_host_application_class_["Woods::Extractors::EngineExtractor#host_application_class?"]
  Woods__Extractors__EngineExtractor_build_mount_map["Woods::Extractors::EngineExtractor#build_mount_map"]
  Woods__Extractors__EngineExtractor_build_mount_map -->|method_call| Rails_application_routes_routes
  Woods__Extractors__EngineExtractor_unwrap_mounted_app["Woods::Extractors::EngineExtractor#unwrap_mounted_app"]
  Woods__Extractors__EngineExtractor_engine_class_["Woods::Extractors::EngineExtractor#engine_class?"]
  Woods__Extractors__EngineExtractor_extract_mount_path["Woods::Extractors::EngineExtractor#extract_mount_path"]
  Woods__Extractors__EngineExtractor_extract_engine["Woods::Extractors::EngineExtractor#extract_engine"]
  Woods__Extractors__EngineExtractor_extract_engine -->|method_call| ExtractedUnit
  Woods__Extractors__EngineExtractor_extract_engine -->|method_call| Rails_logger
  Woods__Extractors__EngineExtractor_extract_engine -->|method_call| Rails
  Woods__Extractors__EngineExtractor_framework_engine_["Woods::Extractors::EngineExtractor#framework_engine?"]
  Woods__Extractors__EngineExtractor_count_engine_routes["Woods::Extractors::EngineExtractor#count_engine_routes"]
  Woods__Extractors__EngineExtractor_extract_engine_controllers["Woods::Extractors::EngineExtractor#extract_engine_controllers"]
  Woods__Extractors__EngineExtractor_extract_engine_controllers -->|method_call| Set
  Woods__Extractors__EngineExtractor_build_engine_source["Woods::Extractors::EngineExtractor#build_engine_source"]
  Woods__Extractors__EngineExtractor_build_engine_dependencies["Woods::Extractors::EngineExtractor#build_engine_dependencies"]
  Woods__Extractors__EventExtractor["Woods::Extractors::EventExtractor"]
  Woods__Extractors__EventExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__EventExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__EventExtractor_initialize["Woods::Extractors::EventExtractor#initialize"]
  APP_DIRECTORIES_map["APP_DIRECTORIES.map"]
  Woods__Extractors__EventExtractor_initialize -->|method_call| APP_DIRECTORIES_map
  APP_DIRECTORIES["APP_DIRECTORIES"]
  Woods__Extractors__EventExtractor_initialize -->|method_call| APP_DIRECTORIES
  Woods__Extractors__EventExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__EventExtractor_initialize -->|method_call| Rails
  Woods__Extractors__EventExtractor_extract_all["Woods::Extractors::EventExtractor#extract_all"]
  Woods__Extractors__EventExtractor_scan_file["Woods::Extractors::EventExtractor#scan_file"]
  Woods__Extractors__EventExtractor_scan_file -->|method_call| File
  Woods__Extractors__EventExtractor_scan_file -->|method_call| Rails_logger
  Woods__Extractors__EventExtractor_scan_file -->|method_call| Rails
  Woods__Extractors__EventExtractor_scan_active_support_notifications["Woods::Extractors::EventExtractor#scan_active_support_notifications"]
  Woods__Extractors__EventExtractor_scan_wisper_patterns["Woods::Extractors::EventExtractor#scan_wisper_patterns"]
  Woods__Extractors__EventExtractor_wisper_context_["Woods::Extractors::EventExtractor#wisper_context?"]
  Woods__Extractors__EventExtractor_register_publisher["Woods::Extractors::EventExtractor#register_publisher"]
  Woods__Extractors__EventExtractor_register_subscriber["Woods::Extractors::EventExtractor#register_subscriber"]
  Woods__Extractors__EventExtractor_build_unit["Woods::Extractors::EventExtractor#build_unit"]
  Woods__Extractors__EventExtractor_build_unit -->|method_call| ExtractedUnit
  Woods__Extractors__EventExtractor_load_source_files["Woods::Extractors::EventExtractor#load_source_files"]
  Woods__Extractors__EventExtractor_load_source_files -->|method_call| File
  Woods__Extractors__EventExtractor_build_source_annotation["Woods::Extractors::EventExtractor#build_source_annotation"]
  Woods__Extractors__EventExtractor_build_dependencies["Woods::Extractors::EventExtractor#build_dependencies"]
  Woods__Extractors__FactoryExtractor["Woods::Extractors::FactoryExtractor"]
  Woods__Extractors__FactoryExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__FactoryExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__FactoryExtractor_initialize["Woods::Extractors::FactoryExtractor#initialize"]
  FACTORY_DIRECTORIES_map["FACTORY_DIRECTORIES.map"]
  Woods__Extractors__FactoryExtractor_initialize -->|method_call| FACTORY_DIRECTORIES_map
  FACTORY_DIRECTORIES["FACTORY_DIRECTORIES"]
  Woods__Extractors__FactoryExtractor_initialize -->|method_call| FACTORY_DIRECTORIES
  Woods__Extractors__FactoryExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__FactoryExtractor_initialize -->|method_call| Rails
  Woods__Extractors__FactoryExtractor_extract_all["Woods::Extractors::FactoryExtractor#extract_all"]
  Woods__Extractors__FactoryExtractor_extract_factory_file["Woods::Extractors::FactoryExtractor#extract_factory_file"]
  Woods__Extractors__FactoryExtractor_extract_factory_file -->|method_call| File
  Woods__Extractors__FactoryExtractor_extract_factory_file -->|method_call| Rails_logger
  Woods__Extractors__FactoryExtractor_extract_factory_file -->|method_call| Rails
  Woods__Extractors__FactoryExtractor_parse_factories["Woods::Extractors::FactoryExtractor#parse_factories"]
  Woods__Extractors__FactoryExtractor_match_factory["Woods::Extractors::FactoryExtractor#match_factory"]
  Woods__Extractors__FactoryExtractor_classify["Woods::Extractors::FactoryExtractor#classify"]
  Woods__Extractors__FactoryExtractor_opens_block_["Woods::Extractors::FactoryExtractor#opens_block?"]
  Woods__Extractors__FactoryExtractor_block_opener_["Woods::Extractors::FactoryExtractor#block_opener?"]
  Woods__Extractors__FactoryExtractor_build_unit["Woods::Extractors::FactoryExtractor#build_unit"]
  Woods__Extractors__FactoryExtractor_build_unit -->|method_call| ExtractedUnit
  Woods__Extractors__FactoryExtractor_build_source_annotation["Woods::Extractors::FactoryExtractor#build_source_annotation"]
  Woods__Extractors__FactoryExtractor_build_metadata["Woods::Extractors::FactoryExtractor#build_metadata"]
  Woods__Extractors__FactoryExtractor_extract_dependencies["Woods::Extractors::FactoryExtractor#extract_dependencies"]
  Woods__Extractors__GraphQLExtractor["Woods::Extractors::GraphQLExtractor"]
  Woods__Extractors__GraphQLExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__GraphQLExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__GraphQLExtractor -->|include| SourceNesting
  Woods__Extractors__GraphQLExtractor_initialize["Woods::Extractors::GraphQLExtractor#initialize"]
  Woods__Extractors__GraphQLExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__GraphQLExtractor_initialize -->|method_call| Rails
  Woods__Extractors__GraphQLExtractor_discoverable_classes["Woods::Extractors::GraphQLExtractor#discoverable_classes"]
  Woods__Extractors__GraphQLExtractor_extract_all["Woods::Extractors::GraphQLExtractor#extract_all"]
  Woods__Extractors__GraphQLExtractor_extract_all -->|method_call| Set
  Woods__Extractors__GraphQLExtractor_extract_all -->|method_call| Dir___
  Woods__Extractors__GraphQLExtractor_extract_graphql_file["Woods::Extractors::GraphQLExtractor#extract_graphql_file"]
  Woods__Extractors__GraphQLExtractor_extract_graphql_file -->|method_call| File
  Woods__Extractors__GraphQLExtractor_extract_graphql_file -->|method_call| ExtractedUnit
  Woods__Extractors__GraphQLExtractor_extract_graphql_file -->|method_call| Rails_logger
  Woods__Extractors__GraphQLExtractor_extract_graphql_file -->|method_call| Rails
  Woods__Extractors__GraphQLExtractor_extract_from_runtime_type["Woods::Extractors::GraphQLExtractor#extract_from_runtime_type"]
  Woods__Extractors__GraphQLExtractor_extract_from_runtime_type -->|method_call| File
  Woods__Extractors__GraphQLExtractor_extract_from_runtime_type -->|method_call| ExtractedUnit
  Woods__Extractors__GraphQLExtractor_extract_from_runtime_type -->|method_call| Rails_logger
  Woods__Extractors__GraphQLExtractor_extract_from_runtime_type -->|method_call| Rails
  Woods__Extractors__GraphQLExtractor_graphql_source_present_["Woods::Extractors::GraphQLExtractor#graphql_source_present?"]
  Woods__Extractors__GraphQLExtractor_find_schema_class["Woods::Extractors::GraphQLExtractor#find_schema_class"]
  GraphQL__Schema_descendants["GraphQL::Schema.descendants"]
  Woods__Extractors__GraphQLExtractor_find_schema_class -->|method_call| GraphQL__Schema_descendants
  Woods__Extractors__GraphQLExtractor_load_runtime_types["Woods::Extractors::GraphQLExtractor#load_runtime_types"]
  Woods__Extractors__GraphQLExtractor_source_file_for_class["Woods::Extractors::GraphQLExtractor#source_file_for_class"]
  Woods__Extractors__GraphQLExtractor_source_file_for_class -->|method_call| Rails_root_join
  Woods__Extractors__GraphQLExtractor_source_file_for_class -->|method_call| Rails_root
  Woods__Extractors__GraphQLExtractor_source_file_for_class -->|method_call| Rails
  Woods__Extractors__GraphQLExtractor_source_file_for_class -->|method_call| File
  Woods__Extractors__GraphQLExtractor_classify_runtime_type["Woods::Extractors::GraphQLExtractor#classify_runtime_type"]
  Woods__Extractors__GraphQLExtractor_classify_unit_type["Woods::Extractors::GraphQLExtractor#classify_unit_type"]
  Woods__Extractors__GraphQLExtractor_graphql_class_["Woods::Extractors::GraphQLExtractor#graphql_class?"]
  Woods__Extractors__GraphQLExtractor_extract_class_name["Woods::Extractors::GraphQLExtractor#extract_class_name"]
  Woods__Extractors__GraphQLExtractor_build_annotated_source["Woods::Extractors::GraphQLExtractor#build_annotated_source"]
  Woods__Extractors__GraphQLExtractor_format_type_label["Woods::Extractors::GraphQLExtractor#format_type_label"]
  Woods__Extractors__GraphQLExtractor_build_metadata["Woods::Extractors::GraphQLExtractor#build_metadata"]
  Woods__Extractors__GraphQLExtractor_detect_graphql_kind["Woods::Extractors::GraphQLExtractor#detect_graphql_kind"]
  Woods__Extractors__GraphQLExtractor_extract_parent_class["Woods::Extractors::GraphQLExtractor#extract_parent_class"]
  Woods__Extractors__GraphQLExtractor_extract_fields["Woods::Extractors::GraphQLExtractor#extract_fields"]
  Woods__Extractors__GraphQLExtractor_extract_fields_from_runtime["Woods::Extractors::GraphQLExtractor#extract_fields_from_runtime"]
  Woods__Extractors__GraphQLExtractor_field_nullable_["Woods::Extractors::GraphQLExtractor#field_nullable?"]
  Woods__Extractors__GraphQLExtractor_extract_fields_from_source["Woods::Extractors::GraphQLExtractor#extract_fields_from_source"]
  Woods__Extractors__GraphQLExtractor_extract_arguments["Woods::Extractors::GraphQLExtractor#extract_arguments"]
  Woods__Extractors__GraphQLExtractor_extract_arguments_from_runtime["Woods::Extractors::GraphQLExtractor#extract_arguments_from_runtime"]
  Woods__Extractors__GraphQLExtractor_extract_arguments_from_source["Woods::Extractors::GraphQLExtractor#extract_arguments_from_source"]
  Woods__Extractors__GraphQLExtractor_extract_interfaces["Woods::Extractors::GraphQLExtractor#extract_interfaces"]
  Woods__Extractors__GraphQLExtractor_extract_connections["Woods::Extractors::GraphQLExtractor#extract_connections"]
  Woods__Extractors__GraphQLExtractor_extract_resolver_references["Woods::Extractors::GraphQLExtractor#extract_resolver_references"]
  Woods__Extractors__GraphQLExtractor_extract_authorization["Woods::Extractors::GraphQLExtractor#extract_authorization"]
  Woods__Extractors__GraphQLExtractor_extract_complexity["Woods::Extractors::GraphQLExtractor#extract_complexity"]
  Woods__Extractors__GraphQLExtractor_extract_enum_values["Woods::Extractors::GraphQLExtractor#extract_enum_values"]
  Woods__Extractors__GraphQLExtractor_extract_union_members["Woods::Extractors::GraphQLExtractor#extract_union_members"]
  Woods__Extractors__GraphQLExtractor_count_fields["Woods::Extractors::GraphQLExtractor#count_fields"]
  Woods__Extractors__GraphQLExtractor_count_arguments["Woods::Extractors::GraphQLExtractor#count_arguments"]
  Woods__Extractors__GraphQLExtractor_extract_dependencies["Woods::Extractors::GraphQLExtractor#extract_dependencies"]
  Woods__Extractors__GraphQLExtractor_build_chunks["Woods::Extractors::GraphQLExtractor#build_chunks"]
  Woods__Extractors__GraphQLExtractor_build_summary_chunk["Woods::Extractors::GraphQLExtractor#build_summary_chunk"]
  Woods__Extractors__GraphQLExtractor_build_field_group_chunk["Woods::Extractors::GraphQLExtractor#build_field_group_chunk"]
  Woods__Extractors__GraphQLExtractor_build_arguments_chunk["Woods::Extractors::GraphQLExtractor#build_arguments_chunk"]
  Woods__Extractors__I18nExtractor["Woods::Extractors::I18nExtractor"]
  Woods__Extractors__I18nExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__I18nExtractor_initialize["Woods::Extractors::I18nExtractor#initialize"]
  I18N_DIRECTORIES_map["I18N_DIRECTORIES.map"]
  Woods__Extractors__I18nExtractor_initialize -->|method_call| I18N_DIRECTORIES_map
  I18N_DIRECTORIES["I18N_DIRECTORIES"]
  Woods__Extractors__I18nExtractor_initialize -->|method_call| I18N_DIRECTORIES
  Woods__Extractors__I18nExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__I18nExtractor_initialize -->|method_call| Rails
  Woods__Extractors__I18nExtractor_extract_all["Woods::Extractors::I18nExtractor#extract_all"]
  Woods__Extractors__I18nExtractor_extract_i18n_file["Woods::Extractors::I18nExtractor#extract_i18n_file"]
  Woods__Extractors__I18nExtractor_extract_i18n_file -->|method_call| File
  YAML["YAML"]
  Woods__Extractors__I18nExtractor_extract_i18n_file -->|method_call| YAML
  Woods__Extractors__I18nExtractor_extract_i18n_file -->|method_call| ExtractedUnit
  Woods__Extractors__I18nExtractor_extract_i18n_file -->|method_call| Rails_logger
  Woods__Extractors__I18nExtractor_extract_i18n_file -->|method_call| Rails
  Woods__Extractors__I18nExtractor_build_identifier["Woods::Extractors::I18nExtractor#build_identifier"]
  Woods__Extractors__I18nExtractor_build_metadata["Woods::Extractors::I18nExtractor#build_metadata"]
  Woods__Extractors__I18nExtractor_flatten_keys["Woods::Extractors::I18nExtractor#flatten_keys"]
  Woods__Extractors__JobExtractor["Woods::Extractors::JobExtractor"]
  Woods__Extractors__JobExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__JobExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__JobExtractor_initialize["Woods::Extractors::JobExtractor#initialize"]
  JOB_DIRECTORIES_map["JOB_DIRECTORIES.map"]
  Woods__Extractors__JobExtractor_initialize -->|method_call| JOB_DIRECTORIES_map
  JOB_DIRECTORIES["JOB_DIRECTORIES"]
  Woods__Extractors__JobExtractor_initialize -->|method_call| JOB_DIRECTORIES
  Woods__Extractors__JobExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__JobExtractor_initialize -->|method_call| Rails
  Woods__Extractors__JobExtractor_extract_all["Woods::Extractors::JobExtractor#extract_all"]
  ApplicationJob_descendants["ApplicationJob.descendants"]
  Woods__Extractors__JobExtractor_extract_all -->|method_call| ApplicationJob_descendants
  Woods__Extractors__JobExtractor_extract_job_file["Woods::Extractors::JobExtractor#extract_job_file"]
  Woods__Extractors__JobExtractor_extract_job_file -->|method_call| File
  Woods__Extractors__JobExtractor_extract_job_file -->|method_call| ExtractedUnit
  Woods__Extractors__JobExtractor_extract_job_file -->|method_call| Rails_logger
  Woods__Extractors__JobExtractor_extract_job_file -->|method_call| Rails
  Woods__Extractors__JobExtractor_extract_job_class["Woods::Extractors::JobExtractor#extract_job_class"]
  Woods__Extractors__JobExtractor_extract_job_class -->|method_call| File
  Woods__Extractors__JobExtractor_extract_job_class -->|method_call| ExtractedUnit
  Woods__Extractors__JobExtractor_extract_job_class -->|method_call| Rails_logger
  Woods__Extractors__JobExtractor_extract_job_class -->|method_call| Rails
  Woods__Extractors__JobExtractor_extract_class_name["Woods::Extractors::JobExtractor#extract_class_name"]
  Woods__Extractors__JobExtractor_job_file_["Woods::Extractors::JobExtractor#job_file?"]
  Woods__Extractors__JobExtractor_source_file_for["Woods::Extractors::JobExtractor#source_file_for"]
  Woods__Extractors__JobExtractor_source_file_for -->|method_call| Rails_root_join
  Woods__Extractors__JobExtractor_source_file_for -->|method_call| Rails_root
  Woods__Extractors__JobExtractor_source_file_for -->|method_call| Rails
  Woods__Extractors__JobExtractor_source_file_for -->|method_call| File
  Woods__Extractors__JobExtractor_annotate_source["Woods::Extractors::JobExtractor#annotate_source"]
  Woods__Extractors__JobExtractor_detect_job_type["Woods::Extractors::JobExtractor#detect_job_type"]
  Woods__Extractors__JobExtractor_extract_queue["Woods::Extractors::JobExtractor#extract_queue"]
  Woods__Extractors__JobExtractor_extract_queue -->|method_call| Regexp
  Woods__Extractors__JobExtractor_extract_metadata_from_source["Woods::Extractors::JobExtractor#extract_metadata_from_source"]
  Woods__Extractors__JobExtractor_extract_metadata_from_class["Woods::Extractors::JobExtractor#extract_metadata_from_class"]
  Woods__Extractors__JobExtractor_extract_sidekiq_options["Woods::Extractors::JobExtractor#extract_sidekiq_options"]
  Woods__Extractors__JobExtractor_extract_sidekiq_options -->|method_call| Regexp
  Woods__Extractors__JobExtractor_extract_retry_config["Woods::Extractors::JobExtractor#extract_retry_config"]
  Woods__Extractors__JobExtractor_extract_concurrency["Woods::Extractors::JobExtractor#extract_concurrency"]
  Woods__Extractors__JobExtractor_extract_perform_params["Woods::Extractors::JobExtractor#extract_perform_params"]
  Woods__Extractors__JobExtractor_extract_perform_params -->|method_call| Regexp
  Woods__Extractors__JobExtractor_extract_discard_on["Woods::Extractors::JobExtractor#extract_discard_on"]
  Woods__Extractors__JobExtractor_extract_retry_on["Woods::Extractors::JobExtractor#extract_retry_on"]
  Woods__Extractors__JobExtractor_extract_callbacks["Woods::Extractors::JobExtractor#extract_callbacks"]
  Woods__Extractors__JobExtractor_extract_dependencies["Woods::Extractors::JobExtractor#extract_dependencies"]
  Woods__Extractors__JobExtractor_extract_enqueued_jobs["Woods::Extractors::JobExtractor#extract_enqueued_jobs"]
  Woods__Extractors__LibExtractor["Woods::Extractors::LibExtractor"]
  Woods__Extractors__LibExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__LibExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__LibExtractor -->|include| SourceNesting
  Woods__Extractors__LibExtractor_initialize["Woods::Extractors::LibExtractor#initialize"]
  Woods__Extractors__LibExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__LibExtractor_initialize -->|method_call| Rails
  Woods__Extractors__LibExtractor_extract_all["Woods::Extractors::LibExtractor#extract_all"]
  Woods__Extractors__LibExtractor_extract_all -->|method_call| Dir___
  Woods__Extractors__LibExtractor_extract_lib_file["Woods::Extractors::LibExtractor#extract_lib_file"]
  Woods__Extractors__LibExtractor_extract_lib_file -->|method_call| File
  Woods__Extractors__LibExtractor_extract_lib_file -->|method_call| ExtractedUnit
  Woods__Extractors__LibExtractor_extract_lib_file -->|method_call| Rails_logger
  Woods__Extractors__LibExtractor_extract_lib_file -->|method_call| Rails
  Woods__Extractors__LibExtractor_excluded_path_["Woods::Extractors::LibExtractor#excluded_path?"]
  EXCLUDED_SEGMENTS["EXCLUDED_SEGMENTS"]
  Woods__Extractors__LibExtractor_excluded_path_ -->|method_call| EXCLUDED_SEGMENTS
  Woods__Extractors__LibExtractor_infer_class_name["Woods::Extractors::LibExtractor#infer_class_name"]
  Woods__Extractors__LibExtractor_path_based_class_name["Woods::Extractors::LibExtractor#path_based_class_name"]
  Woods__Extractors__LibExtractor_annotate_source["Woods::Extractors::LibExtractor#annotate_source"]
  Woods__Extractors__LibExtractor_extract_metadata["Woods::Extractors::LibExtractor#extract_metadata"]
  Woods__Extractors__LibExtractor_extract_dependencies["Woods::Extractors::LibExtractor#extract_dependencies"]
  Woods__Extractors__MailerExtractor["Woods::Extractors::MailerExtractor"]
  Woods__Extractors__MailerExtractor -->|include| AstSourceExtraction
  Woods__Extractors__MailerExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__MailerExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__MailerExtractor -->|include| RouteHelperResolver
  Woods__Extractors__MailerExtractor_initialize["Woods::Extractors::MailerExtractor#initialize"]
  Woods__Extractors__MailerExtractor_extract_all["Woods::Extractors::MailerExtractor#extract_all"]
  Woods__Extractors__MailerExtractor_discoverable_classes["Woods::Extractors::MailerExtractor#discoverable_classes"]
  Woods__Extractors__MailerExtractor_extract_mailer["Woods::Extractors::MailerExtractor#extract_mailer"]
  Woods__Extractors__MailerExtractor_extract_mailer -->|method_call| ExtractedUnit
  Woods__Extractors__MailerExtractor_extract_mailer -->|method_call| File
  Woods__Extractors__MailerExtractor_extract_mailer -->|method_call| Rails_logger
  Woods__Extractors__MailerExtractor_extract_mailer -->|method_call| Rails
  Woods__Extractors__MailerExtractor_source_file_for["Woods::Extractors::MailerExtractor#source_file_for"]
  Woods__Extractors__MailerExtractor_source_file_for -->|method_call| Rails_root_join
  Woods__Extractors__MailerExtractor_source_file_for -->|method_call| Rails_root
  Woods__Extractors__MailerExtractor_source_file_for -->|method_call| Rails
  Woods__Extractors__MailerExtractor_source_file_for -->|method_call| File
  Woods__Extractors__MailerExtractor_annotate_source["Woods::Extractors::MailerExtractor#annotate_source"]
  Woods__Extractors__MailerExtractor_extract_metadata["Woods::Extractors::MailerExtractor#extract_metadata"]
  Woods__Extractors__MailerExtractor_extract_defaults["Woods::Extractors::MailerExtractor#extract_defaults"]
  Woods__Extractors__MailerExtractor_extract_callbacks["Woods::Extractors::MailerExtractor#extract_callbacks"]
  Woods__Extractors__MailerExtractor_extract_layout["Woods::Extractors::MailerExtractor#extract_layout"]
  Woods__Extractors__MailerExtractor_extract_layout -->|method_call| Regexp
  Woods__Extractors__MailerExtractor_extract_helpers["Woods::Extractors::MailerExtractor#extract_helpers"]
  Woods__Extractors__MailerExtractor_discover_templates["Woods::Extractors::MailerExtractor#discover_templates"]
  Woods__Extractors__MailerExtractor_discover_templates -->|method_call| Rails_root
  Woods__Extractors__MailerExtractor_discover_templates -->|method_call| Rails
  Woods__Extractors__MailerExtractor_extract_dependencies["Woods::Extractors::MailerExtractor#extract_dependencies"]
  Woods__Extractors__MailerExtractor_build_action_chunks["Woods::Extractors::MailerExtractor#build_action_chunks"]
  Woods__Extractors__ManagerExtractor["Woods::Extractors::ManagerExtractor"]
  Woods__Extractors__ManagerExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__ManagerExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__ManagerExtractor_initialize["Woods::Extractors::ManagerExtractor#initialize"]
  MANAGER_DIRECTORIES_map["MANAGER_DIRECTORIES.map"]
  Woods__Extractors__ManagerExtractor_initialize -->|method_call| MANAGER_DIRECTORIES_map
  MANAGER_DIRECTORIES["MANAGER_DIRECTORIES"]
  Woods__Extractors__ManagerExtractor_initialize -->|method_call| MANAGER_DIRECTORIES
  Woods__Extractors__ManagerExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__ManagerExtractor_initialize -->|method_call| Rails
  Woods__Extractors__ManagerExtractor_extract_all["Woods::Extractors::ManagerExtractor#extract_all"]
  Woods__Extractors__ManagerExtractor_extract_manager_file["Woods::Extractors::ManagerExtractor#extract_manager_file"]
  Woods__Extractors__ManagerExtractor_extract_manager_file -->|method_call| File
  Woods__Extractors__ManagerExtractor_extract_manager_file -->|method_call| ExtractedUnit
  Woods__Extractors__ManagerExtractor_extract_manager_file -->|method_call| Rails_logger
  Woods__Extractors__ManagerExtractor_extract_manager_file -->|method_call| Rails
  Woods__Extractors__ManagerExtractor_manager_file_["Woods::Extractors::ManagerExtractor#manager_file?"]
  Woods__Extractors__ManagerExtractor_annotate_source["Woods::Extractors::ManagerExtractor#annotate_source"]
  Woods__Extractors__ManagerExtractor_extract_metadata["Woods::Extractors::ManagerExtractor#extract_metadata"]
  Woods__Extractors__ManagerExtractor_detect_wrapped_model["Woods::Extractors::ManagerExtractor#detect_wrapped_model"]
  Woods__Extractors__ManagerExtractor_detect_wrapped_model -->|method_call| Regexp
  Woods__Extractors__ManagerExtractor_constant_name_for["Woods::Extractors::ManagerExtractor#constant_name_for"]
  Woods__Extractors__ManagerExtractor_detect_delegation_type["Woods::Extractors::ManagerExtractor#detect_delegation_type"]
  Woods__Extractors__ManagerExtractor_extract_delegated_methods["Woods::Extractors::ManagerExtractor#extract_delegated_methods"]
  Woods__Extractors__ManagerExtractor_extract_overridden_methods["Woods::Extractors::ManagerExtractor#extract_overridden_methods"]
  Woods__Extractors__ManagerExtractor_extract_dependencies["Woods::Extractors::ManagerExtractor#extract_dependencies"]
  Woods__Extractors__MiddlewareExtractor["Woods::Extractors::MiddlewareExtractor"]
  Woods__Extractors__MiddlewareExtractor_initialize["Woods::Extractors::MiddlewareExtractor#initialize"]
  Woods__Extractors__MiddlewareExtractor_extract_all["Woods::Extractors::MiddlewareExtractor#extract_all"]
  Woods__Extractors__MiddlewareExtractor_extract_all -->|method_call| Rails_application
  Woods__Extractors__MiddlewareExtractor_extract_all -->|method_call| Rails
  Woods__Extractors__MiddlewareExtractor_extract_all -->|method_call| ExtractedUnit
  Woods__Extractors__MiddlewareExtractor_extract_all -->|method_call| Rails_logger
  Woods__Extractors__MiddlewareExtractor_middleware_available_["Woods::Extractors::MiddlewareExtractor#middleware_available?"]
  Woods__Extractors__MiddlewareExtractor_middleware_available_ -->|method_call| Rails
  Woods__Extractors__MiddlewareExtractor_middleware_available_ -->|method_call| Rails_application
  Woods__Extractors__MiddlewareExtractor_extract_middleware_entries["Woods::Extractors::MiddlewareExtractor#extract_middleware_entries"]
  Woods__Extractors__MiddlewareExtractor_extract_single_middleware["Woods::Extractors::MiddlewareExtractor#extract_single_middleware"]
  Woods__Extractors__MiddlewareExtractor_build_stack_source["Woods::Extractors::MiddlewareExtractor#build_stack_source"]
  Woods__Extractors__MiddlewareExtractor_build_stack_metadata["Woods::Extractors::MiddlewareExtractor#build_stack_metadata"]
  Woods__Extractors__MigrationExtractor["Woods::Extractors::MigrationExtractor"]
  Woods__Extractors__MigrationExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__MigrationExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__MigrationExtractor_initialize["Woods::Extractors::MigrationExtractor#initialize"]
  Woods__Extractors__MigrationExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__MigrationExtractor_initialize -->|method_call| Rails
  Woods__Extractors__MigrationExtractor_extract_all["Woods::Extractors::MigrationExtractor#extract_all"]
  Woods__Extractors__MigrationExtractor_extract_all -->|method_call| Dir
  Woods__Extractors__MigrationExtractor_extract_migration_file["Woods::Extractors::MigrationExtractor#extract_migration_file"]
  Woods__Extractors__MigrationExtractor_extract_migration_file -->|method_call| File
  Woods__Extractors__MigrationExtractor_extract_migration_file -->|method_call| ExtractedUnit
  Woods__Extractors__MigrationExtractor_extract_migration_file -->|method_call| Rails_logger
  Woods__Extractors__MigrationExtractor_extract_migration_file -->|method_call| Rails
  Woods__Extractors__MigrationExtractor_extract_class_name["Woods::Extractors::MigrationExtractor#extract_class_name"]
  Woods__Extractors__MigrationExtractor_migration_class_["Woods::Extractors::MigrationExtractor#migration_class?"]
  Woods__Extractors__MigrationExtractor_extract_metadata["Woods::Extractors::MigrationExtractor#extract_metadata"]
  Woods__Extractors__MigrationExtractor_extract_migration_version["Woods::Extractors::MigrationExtractor#extract_migration_version"]
  Woods__Extractors__MigrationExtractor_extract_migration_version -->|method_call| File
  Woods__Extractors__MigrationExtractor_extract_rails_version["Woods::Extractors::MigrationExtractor#extract_rails_version"]
  Woods__Extractors__MigrationExtractor_detect_direction["Woods::Extractors::MigrationExtractor#detect_direction"]
  Woods__Extractors__MigrationExtractor_extract_tables_affected["Woods::Extractors::MigrationExtractor#extract_tables_affected"]
  TABLE_OPERATIONS["TABLE_OPERATIONS"]
  Woods__Extractors__MigrationExtractor_extract_tables_affected -->|method_call| TABLE_OPERATIONS
  Woods__Extractors__MigrationExtractor_extract_columns_added["Woods::Extractors::MigrationExtractor#extract_columns_added"]
  Woods__Extractors__MigrationExtractor_extract_columns_removed["Woods::Extractors::MigrationExtractor#extract_columns_removed"]
  Woods__Extractors__MigrationExtractor_extract_indexes_added["Woods::Extractors::MigrationExtractor#extract_indexes_added"]
  Woods__Extractors__MigrationExtractor_extract_indexes_removed["Woods::Extractors::MigrationExtractor#extract_indexes_removed"]
  Woods__Extractors__MigrationExtractor_extract_references_added["Woods::Extractors::MigrationExtractor#extract_references_added"]
  Woods__Extractors__MigrationExtractor_extract_references_removed["Woods::Extractors::MigrationExtractor#extract_references_removed"]
  Woods__Extractors__MigrationExtractor_extract_block_columns["Woods::Extractors::MigrationExtractor#extract_block_columns"]
  COLUMN_TYPE_METHODS["COLUMN_TYPE_METHODS"]
  Woods__Extractors__MigrationExtractor_extract_block_columns -->|method_call| COLUMN_TYPE_METHODS
  Woods__Extractors__MigrationExtractor_extract_explicit_column_calls["Woods::Extractors::MigrationExtractor#extract_explicit_column_calls"]
  Woods__Extractors__MigrationExtractor_extract_block_references["Woods::Extractors::MigrationExtractor#extract_block_references"]
  Woods__Extractors__MigrationExtractor_extract_operations["Woods::Extractors::MigrationExtractor#extract_operations"]
  Woods__Extractors__MigrationExtractor_extract_operations -->|method_call| Hash
  Woods__Extractors__MigrationExtractor_extract_operations -->|method_call| TABLE_OPERATIONS
  Woods__Extractors__MigrationExtractor_data_migration_["Woods::Extractors::MigrationExtractor#data_migration?"]
  DATA_MIGRATION_PATTERNS["DATA_MIGRATION_PATTERNS"]
  Woods__Extractors__MigrationExtractor_data_migration_ -->|method_call| DATA_MIGRATION_PATTERNS
  Woods__Extractors__MigrationExtractor_annotate_source["Woods::Extractors::MigrationExtractor#annotate_source"]
  Woods__Extractors__MigrationExtractor_extract_dependencies["Woods::Extractors::MigrationExtractor#extract_dependencies"]
  Woods__Extractors__MigrationExtractor_extract_dependencies -->|method_call| INTERNAL_TABLES
  Woods__Extractors__ModelExtractor["Woods::Extractors::ModelExtractor"]
  Woods__Extractors__ModelExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__ModelExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__ModelExtractor_initialize["Woods::Extractors::ModelExtractor#initialize"]
  Woods__Extractors__ModelExtractor_extract_all["Woods::Extractors::ModelExtractor#extract_all"]
  Woods__Extractors__ModelExtractor_discoverable_classes["Woods::Extractors::ModelExtractor#discoverable_classes"]
  ActiveRecord__Base_descendants_reject_reject["ActiveRecord::Base.descendants.reject.reject"]
  Woods__Extractors__ModelExtractor_discoverable_classes -->|method_call| ActiveRecord__Base_descendants_reject_reject
  Woods__Extractors__ModelExtractor_extract_model["Woods::Extractors::ModelExtractor#extract_model"]
  Woods__Extractors__ModelExtractor_extract_model -->|method_call| ExtractedUnit
  Woods__Extractors__ModelExtractor_extract_model -->|method_call| File
  Woods__Extractors__ModelExtractor_extract_model -->|method_call| Rails_logger
  Woods__Extractors__ModelExtractor_extract_model -->|method_call| Rails
  Woods__Extractors__ModelExtractor_source_file_for["Woods::Extractors::ModelExtractor#source_file_for"]
  Woods__Extractors__ModelExtractor_source_file_for -->|method_call| Rails_root_join
  Woods__Extractors__ModelExtractor_source_file_for -->|method_call| Rails_root
  Woods__Extractors__ModelExtractor_source_file_for -->|method_call| Rails
  Woods__Extractors__ModelExtractor_source_file_for -->|method_call| File
  Woods__Extractors__ModelExtractor_habtm_join_model_["Woods::Extractors::ModelExtractor#habtm_join_model?"]
  Woods__Extractors__ModelExtractor_build_composite_source["Woods::Extractors::ModelExtractor#build_composite_source"]
  Woods__Extractors__ModelExtractor_build_schema_comment["Woods::Extractors::ModelExtractor#build_schema_comment"]
  Woods__Extractors__ModelExtractor_format_columns_comment["Woods::Extractors::ModelExtractor#format_columns_comment"]
  Woods__Extractors__ModelExtractor_format_indexes_comment["Woods::Extractors::ModelExtractor#format_indexes_comment"]
  ActiveRecord__Base_connection_indexes["ActiveRecord::Base.connection.indexes"]
  Woods__Extractors__ModelExtractor_format_indexes_comment -->|method_call| ActiveRecord__Base_connection_indexes
  Woods__Extractors__ModelExtractor_format_foreign_keys_comment["Woods::Extractors::ModelExtractor#format_foreign_keys_comment"]
  ActiveRecord__Base_connection_foreign_keys["ActiveRecord::Base.connection.foreign_keys"]
  Woods__Extractors__ModelExtractor_format_foreign_keys_comment -->|method_call| ActiveRecord__Base_connection_foreign_keys
  Woods__Extractors__ModelExtractor_build_model_source_with_concerns["Woods::Extractors::ModelExtractor#build_model_source_with_concerns"]
  Woods__Extractors__ModelExtractor_build_model_source_with_concerns -->|method_call| File
  Woods__Extractors__ModelExtractor_resolved_concern_sources["Woods::Extractors::ModelExtractor#resolved_concern_sources"]
  Woods__Extractors__ModelExtractor_build_concern_block["Woods::Extractors::ModelExtractor#build_concern_block"]
  Woods__Extractors__ModelExtractor_insert_concern_block["Woods::Extractors::ModelExtractor#insert_concern_block"]
  Woods__Extractors__ModelExtractor_class_declaration_pattern["Woods::Extractors::ModelExtractor#class_declaration_pattern"]
  Woods__Extractors__ModelExtractor_class_declaration_pattern -->|method_call| Regexp
  Woods__Extractors__ModelExtractor_extract_included_modules["Woods::Extractors::ModelExtractor#extract_included_modules"]
  Woods__Extractors__ModelExtractor_extract_included_modules -->|method_call| Rails_root
  Woods__Extractors__ModelExtractor_extract_included_modules -->|method_call| Rails
  Woods__Extractors__ModelExtractor_extract_included_modules -->|method_call| Object
  Woods__Extractors__ModelExtractor_extract_extended_modules["Woods::Extractors::ModelExtractor#extract_extended_modules"]
  Woods__Extractors__ModelExtractor_extract_extended_modules -->|method_call| Rails_root
  Woods__Extractors__ModelExtractor_extract_extended_modules -->|method_call| Rails
  Object_singleton_class_included_modules_map_compact["Object.singleton_class.included_modules.map.compact"]
  Woods__Extractors__ModelExtractor_extract_extended_modules -->|method_call| Object_singleton_class_included_modules_map_compact
  Object_singleton_class_included_modules_map["Object.singleton_class.included_modules.map"]
  Woods__Extractors__ModelExtractor_extract_extended_modules -->|method_call| Object_singleton_class_included_modules_map
  Object_singleton_class_included_modules["Object.singleton_class.included_modules"]
  Woods__Extractors__ModelExtractor_extract_extended_modules -->|method_call| Object_singleton_class_included_modules
  Object_singleton_class["Object.singleton_class"]
  Woods__Extractors__ModelExtractor_extract_extended_modules -->|method_call| Object_singleton_class
  Woods__Extractors__ModelExtractor_extract_extended_modules -->|method_call| Object
  Woods__Extractors__ModelExtractor_defined_in_app_["Woods::Extractors::ModelExtractor#defined_in_app?"]
  Woods__Extractors__ModelExtractor_defined_in_app_ -->|method_call| Rails_root
  Woods__Extractors__ModelExtractor_defined_in_app_ -->|method_call| Rails
  Woods__Extractors__ModelExtractor_defined_in_app_ -->|method_call| Object
  Woods__Extractors__ModelExtractor_concern_source["Woods::Extractors::ModelExtractor#concern_source"]
  Woods__Extractors__ModelExtractor_concern_source -->|method_call| File
  Woods__Extractors__ModelExtractor_concern_path_for["Woods::Extractors::ModelExtractor#concern_path_for"]
  Woods__Extractors__ModelExtractor_concern_path_for -->|method_call| Rails_root
  Woods__Extractors__ModelExtractor_concern_path_for -->|method_call| Rails
  Woods__Extractors__ModelExtractor_concern_path_for -->|method_call| File
  Woods__Extractors__ModelExtractor_extract_metadata["Woods::Extractors::ModelExtractor#extract_metadata"]
  Woods__Extractors__ModelExtractor_extract_active_storage_attachments["Woods::Extractors::ModelExtractor#extract_active_storage_attachments"]
  Woods__Extractors__ModelExtractor_extract_action_text_fields["Woods::Extractors::ModelExtractor#extract_action_text_fields"]
  Woods__Extractors__ModelExtractor_extract_variant_definitions["Woods::Extractors::ModelExtractor#extract_variant_definitions"]
  Woods__Extractors__ModelExtractor_extract_database_roles["Woods::Extractors::ModelExtractor#extract_database_roles"]
  Woods__Extractors__ModelExtractor_extract_shard_config["Woods::Extractors::ModelExtractor#extract_shard_config"]
  Woods__Extractors__ModelExtractor_parse_role_hash["Woods::Extractors::ModelExtractor#parse_role_hash"]
  Woods__Extractors__ModelExtractor_extract_associations["Woods::Extractors::ModelExtractor#extract_associations"]
  Woods__Extractors__ModelExtractor_extract_association_options["Woods::Extractors::ModelExtractor#extract_association_options"]
  Woods__Extractors__ModelExtractor_extract_validations["Woods::Extractors::ModelExtractor#extract_validations"]
  Woods__Extractors__ModelExtractor_extract_callbacks["Woods::Extractors::ModelExtractor#extract_callbacks"]
  Woods__Extractors__ModelExtractor_extract_scopes["Woods::Extractors::ModelExtractor#extract_scopes"]
  Woods__Extractors__ModelExtractor_extract_scopes -->|method_call| File
  Woods__Extractors__ModelExtractor_extract_scopes -->|method_call| Ast__Parser
  Woods__Extractors__ModelExtractor_extract_scopes_from_ast["Woods::Extractors::ModelExtractor#extract_scopes_from_ast"]
  Woods__Extractors__ModelExtractor_extract_scopes_by_regex["Woods::Extractors::ModelExtractor#extract_scopes_by_regex"]
  Woods__Extractors__ModelExtractor_extract_enums["Woods::Extractors::ModelExtractor#extract_enums"]
  Woods__Extractors__ModelExtractor_extract_dependencies["Woods::Extractors::ModelExtractor#extract_dependencies"]
  Woods__Extractors__ModelExtractor_extract_dependencies -->|method_call| File
  Woods__Extractors__ModelExtractor_polymorphic_reflection_["Woods::Extractors::ModelExtractor#polymorphic_reflection?"]
  Woods__Extractors__ModelExtractor_build_analysis_source["Woods::Extractors::ModelExtractor#build_analysis_source"]
  Woods__Extractors__ModelExtractor_enrich_callbacks_with_side_effects["Woods::Extractors::ModelExtractor#enrich_callbacks_with_side_effects"]
  CallbackAnalyzer["CallbackAnalyzer"]
  Woods__Extractors__ModelExtractor_enrich_callbacks_with_side_effects -->|method_call| CallbackAnalyzer
  Woods__Extractors__ModelExtractor_build_chunks["Woods::Extractors::ModelExtractor#build_chunks"]
  Woods__Extractors__ModelExtractor_add_chunk["Woods::Extractors::ModelExtractor#add_chunk"]
  Woods__Extractors__ModelExtractor_build_summary_chunk["Woods::Extractors::ModelExtractor#build_summary_chunk"]
  Woods__Extractors__ModelExtractor_build_associations_chunk["Woods::Extractors::ModelExtractor#build_associations_chunk"]
  Woods__Extractors__ModelExtractor_build_callbacks_chunk["Woods::Extractors::ModelExtractor#build_callbacks_chunk"]
  Woods__Extractors__ModelExtractor_format_callback_line["Woods::Extractors::ModelExtractor#format_callback_line"]
  Woods__Extractors__ModelExtractor_build_callback_effects_chunk["Woods::Extractors::ModelExtractor#build_callback_effects_chunk"]
  Woods__Extractors__ModelExtractor_callback_lifecycle_group["Woods::Extractors::ModelExtractor#callback_lifecycle_group"]
  Woods__Extractors__ModelExtractor_describe_callback_effects["Woods::Extractors::ModelExtractor#describe_callback_effects"]
  Woods__Extractors__ModelExtractor_build_validations_chunk["Woods::Extractors::ModelExtractor#build_validations_chunk"]
  Woods__Extractors__ModelExtractor_format_validation_conditions["Woods::Extractors::ModelExtractor#format_validation_conditions"]
  Woods__Extractors__ModelExtractor_format_callback_conditions["Woods::Extractors::ModelExtractor#format_callback_conditions"]
  Woods__Extractors__ModelExtractor_implicit_belongs_to_validator_["Woods::Extractors::ModelExtractor#implicit_belongs_to_validator?"]
  Woods__Extractors__ModelExtractor_filter_instance_methods["Woods::Extractors::ModelExtractor#filter_instance_methods"]
  AR_INTERNAL_METHOD_PATTERN["AR_INTERNAL_METHOD_PATTERN"]
  Woods__Extractors__ModelExtractor_filter_instance_methods -->|method_call| AR_INTERNAL_METHOD_PATTERN
  Woods__Extractors__ModelExtractor_sti_base_["Woods::Extractors::ModelExtractor#sti_base?"]
  Woods__Extractors__ModelExtractor_sti_child_["Woods::Extractors::ModelExtractor#sti_child?"]
  Woods__Extractors__ModelExtractor_callback_count["Woods::Extractors::ModelExtractor#callback_count"]
  Woods__Extractors__ModelExtractor_count_loc["Woods::Extractors::ModelExtractor#count_loc"]
  Woods__Extractors__ModelExtractor_count_loc -->|method_call| File
  Woods__Extractors__ModelExtractor_count_loc -->|method_call| File_readlines
  Woods__Extractors__PhlexExtractor["Woods::Extractors::PhlexExtractor"]
  Woods__Extractors__PhlexExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__PhlexExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__PhlexExtractor -->|include| RouteHelperResolver
  Woods__Extractors__PhlexExtractor_initialize["Woods::Extractors::PhlexExtractor#initialize"]
  Woods__Extractors__PhlexExtractor_extract_all["Woods::Extractors::PhlexExtractor#extract_all"]
  Woods__Extractors__PhlexExtractor_discoverable_classes["Woods::Extractors::PhlexExtractor#discoverable_classes"]
  Woods__Extractors__PhlexExtractor_extract_component["Woods::Extractors::PhlexExtractor#extract_component"]
  Woods__Extractors__PhlexExtractor_extract_component -->|method_call| ExtractedUnit
  Woods__Extractors__PhlexExtractor_extract_component -->|method_call| Rails_logger
  Woods__Extractors__PhlexExtractor_extract_component -->|method_call| Rails
  Woods__Extractors__PhlexExtractor_find_component_base["Woods::Extractors::PhlexExtractor#find_component_base"]
  PHLEX_BASES["PHLEX_BASES"]
  Woods__Extractors__PhlexExtractor_find_component_base -->|method_call| PHLEX_BASES
  Woods__Extractors__PhlexExtractor_view_component_subclass_["Woods::Extractors::PhlexExtractor#view_component_subclass?"]
  Woods__Extractors__PhlexExtractor_source_file_for["Woods::Extractors::PhlexExtractor#source_file_for"]
  Woods__Extractors__PhlexExtractor_source_file_for -->|method_call| Rails_root
  Woods__Extractors__PhlexExtractor_source_file_for -->|method_call| Rails
  Woods__Extractors__PhlexExtractor_source_file_for -->|method_call| File
  Woods__Extractors__PhlexExtractor_read_source["Woods::Extractors::PhlexExtractor#read_source"]
  Woods__Extractors__PhlexExtractor_read_source -->|method_call| File
  Woods__Extractors__PhlexExtractor_extract_metadata["Woods::Extractors::PhlexExtractor#extract_metadata"]
  Woods__Extractors__PhlexExtractor_extract_slots["Woods::Extractors::PhlexExtractor#extract_slots"]
  Woods__Extractors__PhlexExtractor_extract_renders_many["Woods::Extractors::PhlexExtractor#extract_renders_many"]
  Woods__Extractors__PhlexExtractor_extract_renders_one["Woods::Extractors::PhlexExtractor#extract_renders_one"]
  Woods__Extractors__PhlexExtractor_extract_initialize_params["Woods::Extractors::PhlexExtractor#extract_initialize_params"]
  Woods__Extractors__PhlexExtractor_extract_dependencies["Woods::Extractors::PhlexExtractor#extract_dependencies"]
  Woods__Extractors__PolicyExtractor["Woods::Extractors::PolicyExtractor"]
  Woods__Extractors__PolicyExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__PolicyExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__PolicyExtractor_initialize["Woods::Extractors::PolicyExtractor#initialize"]
  POLICY_DIRECTORIES_map["POLICY_DIRECTORIES.map"]
  Woods__Extractors__PolicyExtractor_initialize -->|method_call| POLICY_DIRECTORIES_map
  POLICY_DIRECTORIES["POLICY_DIRECTORIES"]
  Woods__Extractors__PolicyExtractor_initialize -->|method_call| POLICY_DIRECTORIES
  Woods__Extractors__PolicyExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__PolicyExtractor_initialize -->|method_call| Rails
  Woods__Extractors__PolicyExtractor_extract_all["Woods::Extractors::PolicyExtractor#extract_all"]
  Woods__Extractors__PolicyExtractor_extract_policy_file["Woods::Extractors::PolicyExtractor#extract_policy_file"]
  Woods__Extractors__PolicyExtractor_extract_policy_file -->|method_call| File
  Woods__Extractors__PolicyExtractor_extract_policy_file -->|method_call| ExtractedUnit
  Woods__Extractors__PolicyExtractor_extract_policy_file -->|method_call| Rails_logger
  Woods__Extractors__PolicyExtractor_extract_policy_file -->|method_call| Rails
  Woods__Extractors__PolicyExtractor_annotate_source["Woods::Extractors::PolicyExtractor#annotate_source"]
  Woods__Extractors__PolicyExtractor_extract_metadata["Woods::Extractors::PolicyExtractor#extract_metadata"]
  Woods__Extractors__PolicyExtractor_detect_decision_methods["Woods::Extractors::PolicyExtractor#detect_decision_methods"]
  Woods__Extractors__PolicyExtractor_detect_decision_methods -->|method_call| Regexp
  Woods__Extractors__PolicyExtractor_detect_evaluated_models["Woods::Extractors::PolicyExtractor#detect_evaluated_models"]
  Regexp_last_match_split["Regexp.last_match.split"]
  Woods__Extractors__PolicyExtractor_detect_evaluated_models -->|method_call| Regexp_last_match_split
  Woods__Extractors__PolicyExtractor_detect_evaluated_models -->|method_call| Regexp_last_match
  Woods__Extractors__PolicyExtractor_detect_evaluated_models -->|method_call| Regexp
  Woods__Extractors__PolicyExtractor_pundit_policy_["Woods::Extractors::PolicyExtractor#pundit_policy?"]
  Woods__Extractors__PolicyExtractor_extract_dependencies["Woods::Extractors::PolicyExtractor#extract_dependencies"]
  Woods__Extractors__PoroExtractor["Woods::Extractors::PoroExtractor"]
  Woods__Extractors__PoroExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__PoroExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__PoroExtractor -->|include| SourceNesting
  Woods__Extractors__PoroExtractor_initialize["Woods::Extractors::PoroExtractor#initialize"]
  Woods__Extractors__PoroExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__PoroExtractor_initialize -->|method_call| Rails
  Woods__Extractors__PoroExtractor_extract_all["Woods::Extractors::PoroExtractor#extract_all"]
  Woods__Extractors__PoroExtractor_extract_all -->|method_call| ActiveRecord__Base_descendants_filter_map
  Woods__Extractors__PoroExtractor_extract_all -->|method_call| ActiveRecord__Base_descendants
  Woods__Extractors__PoroExtractor_extract_all -->|method_call| ActiveRecord__Base
  Woods__Extractors__PoroExtractor_extract_all -->|method_call| Dir___
  Woods__Extractors__PoroExtractor_extract_poro_file["Woods::Extractors::PoroExtractor#extract_poro_file"]
  Woods__Extractors__PoroExtractor_extract_poro_file -->|method_call| File
  Woods__Extractors__PoroExtractor_extract_poro_file -->|method_call| ExtractedUnit
  Woods__Extractors__PoroExtractor_extract_poro_file -->|method_call| Rails_logger
  Woods__Extractors__PoroExtractor_extract_poro_file -->|method_call| Rails
  Woods__Extractors__PoroExtractor_poro_file_["Woods::Extractors::PoroExtractor#poro_file?"]
  Woods__Extractors__PoroExtractor_module_only_["Woods::Extractors::PoroExtractor#module_only?"]
  Woods__Extractors__PoroExtractor_infer_class_name["Woods::Extractors::PoroExtractor#infer_class_name"]
  Woods__Extractors__PoroExtractor_path_based_class_name["Woods::Extractors::PoroExtractor#path_based_class_name"]
  Woods__Extractors__PoroExtractor_annotate_source["Woods::Extractors::PoroExtractor#annotate_source"]
  Woods__Extractors__PoroExtractor_extract_metadata["Woods::Extractors::PoroExtractor#extract_metadata"]
  Woods__Extractors__PoroExtractor_extract_dependencies["Woods::Extractors::PoroExtractor#extract_dependencies"]
  Woods__Extractors__PunditExtractor["Woods::Extractors::PunditExtractor"]
  Woods__Extractors__PunditExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__PunditExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__PunditExtractor_initialize["Woods::Extractors::PunditExtractor#initialize"]
  PUNDIT_DIRECTORIES_map["PUNDIT_DIRECTORIES.map"]
  Woods__Extractors__PunditExtractor_initialize -->|method_call| PUNDIT_DIRECTORIES_map
  PUNDIT_DIRECTORIES["PUNDIT_DIRECTORIES"]
  Woods__Extractors__PunditExtractor_initialize -->|method_call| PUNDIT_DIRECTORIES
  Woods__Extractors__PunditExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__PunditExtractor_initialize -->|method_call| Rails
  Woods__Extractors__PunditExtractor_extract_all["Woods::Extractors::PunditExtractor#extract_all"]
  Woods__Extractors__PunditExtractor_extract_pundit_file["Woods::Extractors::PunditExtractor#extract_pundit_file"]
  Woods__Extractors__PunditExtractor_extract_pundit_file -->|method_call| File
  Woods__Extractors__PunditExtractor_extract_pundit_file -->|method_call| ExtractedUnit
  Woods__Extractors__PunditExtractor_extract_pundit_file -->|method_call| Rails_logger
  Woods__Extractors__PunditExtractor_extract_pundit_file -->|method_call| Rails
  Woods__Extractors__PunditExtractor_extract_class_name["Woods::Extractors::PunditExtractor#extract_class_name"]
  Woods__Extractors__PunditExtractor_pundit_policy_["Woods::Extractors::PunditExtractor#pundit_policy?"]
  Woods__Extractors__PunditExtractor_annotate_source["Woods::Extractors::PunditExtractor#annotate_source"]
  Woods__Extractors__PunditExtractor_extract_metadata["Woods::Extractors::PunditExtractor#extract_metadata"]
  Woods__Extractors__PunditExtractor_detect_authorization_actions["Woods::Extractors::PunditExtractor#detect_authorization_actions"]
  Woods__Extractors__PunditExtractor_infer_model["Woods::Extractors::PunditExtractor#infer_model"]
  Woods__Extractors__PunditExtractor_extract_dependencies["Woods::Extractors::PunditExtractor#extract_dependencies"]
  Woods__Extractors__RailsSourceExtractor["Woods::Extractors::RailsSourceExtractor"]
  Woods__Extractors__RailsSourceExtractor_initialize["Woods::Extractors::RailsSourceExtractor#initialize"]
  Woods__Extractors__RailsSourceExtractor_initialize -->|method_call| Rails
  Woods__Extractors__RailsSourceExtractor_extract_all["Woods::Extractors::RailsSourceExtractor#extract_all"]
  Woods__Extractors__RailsSourceExtractor_extract_rails_sources["Woods::Extractors::RailsSourceExtractor#extract_rails_sources"]
  RAILS_PATHS["RAILS_PATHS"]
  Woods__Extractors__RailsSourceExtractor_extract_rails_sources -->|method_call| RAILS_PATHS
  Woods__Extractors__RailsSourceExtractor_extract_rails_sources -->|method_call| Dir___
  Woods__Extractors__RailsSourceExtractor_extract_gem_sources["Woods::Extractors::RailsSourceExtractor#extract_gem_sources"]
  GEM_CONFIGS["GEM_CONFIGS"]
  Woods__Extractors__RailsSourceExtractor_extract_gem_sources -->|method_call| GEM_CONFIGS
  Woods__Extractors__RailsSourceExtractor_extract_gem_sources -->|method_call| Dir___
  Woods__Extractors__RailsSourceExtractor_find_gem_path["Woods::Extractors::RailsSourceExtractor#find_gem_path"]
  Gem__Specification["Gem::Specification"]
  Woods__Extractors__RailsSourceExtractor_find_gem_path -->|method_call| Gem__Specification
  Woods__Extractors__RailsSourceExtractor_find_gem_path -->|method_call| Pathname
  Woods__Extractors__RailsSourceExtractor_gem_version["Woods::Extractors::RailsSourceExtractor#gem_version"]
  Gem__Specification_find_by_name_version["Gem::Specification.find_by_name.version"]
  Woods__Extractors__RailsSourceExtractor_gem_version -->|method_call| Gem__Specification_find_by_name_version
  Gem__Specification_find_by_name["Gem::Specification.find_by_name"]
  Woods__Extractors__RailsSourceExtractor_gem_version -->|method_call| Gem__Specification_find_by_name
  Woods__Extractors__RailsSourceExtractor_gem_version -->|method_call| Gem__Specification
  Woods__Extractors__RailsSourceExtractor_extract_framework_file["Woods::Extractors::RailsSourceExtractor#extract_framework_file"]
  Woods__Extractors__RailsSourceExtractor_extract_framework_file -->|method_call| File
  Woods__Extractors__RailsSourceExtractor_extract_framework_file -->|method_call| ExtractedUnit
  Woods__Extractors__RailsSourceExtractor_extract_framework_file -->|method_call| Rails_logger
  Woods__Extractors__RailsSourceExtractor_extract_framework_file -->|method_call| Rails
  Woods__Extractors__RailsSourceExtractor_extract_gem_file["Woods::Extractors::RailsSourceExtractor#extract_gem_file"]
  Woods__Extractors__RailsSourceExtractor_extract_gem_file -->|method_call| File
  Woods__Extractors__RailsSourceExtractor_extract_gem_file -->|method_call| ExtractedUnit
  Woods__Extractors__RailsSourceExtractor_extract_gem_file -->|method_call| Rails_logger
  Woods__Extractors__RailsSourceExtractor_extract_gem_file -->|method_call| Rails
  Woods__Extractors__RailsSourceExtractor_annotate_framework_source["Woods::Extractors::RailsSourceExtractor#annotate_framework_source"]
  Woods__Extractors__RailsSourceExtractor_annotate_gem_source["Woods::Extractors::RailsSourceExtractor#annotate_gem_source"]
  Woods__Extractors__RailsSourceExtractor_extract_module_names["Woods::Extractors::RailsSourceExtractor#extract_module_names"]
  Woods__Extractors__RailsSourceExtractor_extract_class_names["Woods::Extractors::RailsSourceExtractor#extract_class_names"]
  Woods__Extractors__RailsSourceExtractor_extract_public_api["Woods::Extractors::RailsSourceExtractor#extract_public_api"]
  Woods__Extractors__RailsSourceExtractor_extract_public_api -->|method_call| Regexp
  Woods__Extractors__RailsSourceExtractor_extract_dsl_methods["Woods::Extractors::RailsSourceExtractor#extract_dsl_methods"]
  Woods__Extractors__RailsSourceExtractor_extract_option_definitions["Woods::Extractors::RailsSourceExtractor#extract_option_definitions"]
  Woods__Extractors__RailsSourceExtractor_public_api_file_["Woods::Extractors::RailsSourceExtractor#public_api_file?"]
  Woods__Extractors__RailsSourceExtractor_rate_importance["Woods::Extractors::RailsSourceExtractor#rate_importance"]
  Woods__Extractors__RailsSourceExtractor_extract_mixins["Woods::Extractors::RailsSourceExtractor#extract_mixins"]
  Woods__Extractors__RailsSourceExtractor_extract_configuration["Woods::Extractors::RailsSourceExtractor#extract_configuration"]
  Woods__Extractors__RakeTaskExtractor["Woods::Extractors::RakeTaskExtractor"]
  Woods__Extractors__RakeTaskExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__RakeTaskExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__RakeTaskExtractor_initialize["Woods::Extractors::RakeTaskExtractor#initialize"]
  RAKE_DIRECTORIES_map["RAKE_DIRECTORIES.map"]
  Woods__Extractors__RakeTaskExtractor_initialize -->|method_call| RAKE_DIRECTORIES_map
  RAKE_DIRECTORIES["RAKE_DIRECTORIES"]
  Woods__Extractors__RakeTaskExtractor_initialize -->|method_call| RAKE_DIRECTORIES
  Woods__Extractors__RakeTaskExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__RakeTaskExtractor_initialize -->|method_call| Rails
  Woods__Extractors__RakeTaskExtractor_extract_all["Woods::Extractors::RakeTaskExtractor#extract_all"]
  Woods__Extractors__RakeTaskExtractor_extract_rake_file["Woods::Extractors::RakeTaskExtractor#extract_rake_file"]
  Woods__Extractors__RakeTaskExtractor_extract_rake_file -->|method_call| File
  Woods__Extractors__RakeTaskExtractor_extract_rake_file -->|method_call| Rails_logger
  Woods__Extractors__RakeTaskExtractor_extract_rake_file -->|method_call| Rails
  Woods__Extractors__RakeTaskExtractor_parse_tasks["Woods::Extractors::RakeTaskExtractor#parse_tasks"]
  Woods__Extractors__RakeTaskExtractor_extract_namespace_name["Woods::Extractors::RakeTaskExtractor#extract_namespace_name"]
  Woods__Extractors__RakeTaskExtractor_extract_desc["Woods::Extractors::RakeTaskExtractor#extract_desc"]
  Woods__Extractors__RakeTaskExtractor_parse_task_line["Woods::Extractors::RakeTaskExtractor#parse_task_line"]
  Woods__Extractors__RakeTaskExtractor_parse_task_signature["Woods::Extractors::RakeTaskExtractor#parse_task_signature"]
  Woods__Extractors__RakeTaskExtractor_parse_task_signature -->|method_call| Regexp
  Regexp_last_match_scan["Regexp.last_match.scan"]
  Woods__Extractors__RakeTaskExtractor_parse_task_signature -->|method_call| Regexp_last_match_scan
  Woods__Extractors__RakeTaskExtractor_parse_task_signature -->|method_call| Regexp_last_match
  Woods__Extractors__RakeTaskExtractor_parse_dependency_list["Woods::Extractors::RakeTaskExtractor#parse_dependency_list"]
  Woods__Extractors__RakeTaskExtractor_extract_task_block["Woods::Extractors::RakeTaskExtractor#extract_task_block"]
  Woods__Extractors__RakeTaskExtractor_block_opener_["Woods::Extractors::RakeTaskExtractor#block_opener?"]
  Woods__Extractors__RakeTaskExtractor_excluded_namespace_["Woods::Extractors::RakeTaskExtractor#excluded_namespace?"]
  EXCLUDED_NAMESPACES["EXCLUDED_NAMESPACES"]
  Woods__Extractors__RakeTaskExtractor_excluded_namespace_ -->|method_call| EXCLUDED_NAMESPACES
  Woods__Extractors__RakeTaskExtractor_build_unit["Woods::Extractors::RakeTaskExtractor#build_unit"]
  Woods__Extractors__RakeTaskExtractor_build_unit -->|method_call| ExtractedUnit
  Woods__Extractors__RakeTaskExtractor_build_source_annotation["Woods::Extractors::RakeTaskExtractor#build_source_annotation"]
  Woods__Extractors__RakeTaskExtractor_build_metadata["Woods::Extractors::RakeTaskExtractor#build_metadata"]
  Woods__Extractors__RakeTaskExtractor_extract_dependencies["Woods::Extractors::RakeTaskExtractor#extract_dependencies"]
  Woods__Extractors__RouteExtractor["Woods::Extractors::RouteExtractor"]
  Woods__Extractors__RouteExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__RouteExtractor_initialize["Woods::Extractors::RouteExtractor#initialize"]
  Woods__Extractors__RouteExtractor_extract_all["Woods::Extractors::RouteExtractor#extract_all"]
  Rails_application_routes["Rails.application.routes"]
  Woods__Extractors__RouteExtractor_extract_all -->|method_call| Rails_application_routes
  Woods__Extractors__RouteExtractor_extract_all -->|method_call| Rails_application
  Woods__Extractors__RouteExtractor_extract_all -->|method_call| Rails
  Woods__Extractors__RouteExtractor_rails_routes_available_["Woods::Extractors::RouteExtractor#rails_routes_available?"]
  Woods__Extractors__RouteExtractor_rails_routes_available_ -->|method_call| Rails
  Woods__Extractors__RouteExtractor_rails_routes_available_ -->|method_call| Rails_application
  Woods__Extractors__RouteExtractor_rails_routes_available_ -->|method_call| Rails_application_routes
  Woods__Extractors__RouteExtractor_extract_route["Woods::Extractors::RouteExtractor#extract_route"]
  Woods__Extractors__RouteExtractor_extract_route -->|method_call| ExtractedUnit
  Woods__Extractors__RouteExtractor_extract_route -->|method_call| Rails_logger
  Woods__Extractors__RouteExtractor_extract_route -->|method_call| Rails
  Woods__Extractors__RouteExtractor_route_defaults["Woods::Extractors::RouteExtractor#route_defaults"]
  Woods__Extractors__RouteExtractor_route_verb["Woods::Extractors::RouteExtractor#route_verb"]
  Woods__Extractors__RouteExtractor_route_path["Woods::Extractors::RouteExtractor#route_path"]
  Woods__Extractors__RouteExtractor_build_route_source["Woods::Extractors::RouteExtractor#build_route_source"]
  Woods__Extractors__RouteExtractor_build_route_metadata["Woods::Extractors::RouteExtractor#build_route_metadata"]
  Woods__Extractors__RouteExtractor_route_constraints["Woods::Extractors::RouteExtractor#route_constraints"]
  Woods__Extractors__RouteExtractor_build_route_dependencies["Woods::Extractors::RouteExtractor#build_route_dependencies"]
  Woods__Extractors__RouteHelperResolver["Woods::Extractors::RouteHelperResolver"]
  Woods__Extractors__RouteHelperResolver_build_route_helper_map["Woods::Extractors::RouteHelperResolver#build_route_helper_map"]
  Woods__Extractors__RouteHelperResolver_safe_rails_application_routes["Woods::Extractors::RouteHelperResolver#safe_rails_application_routes"]
  Woods__Extractors__RouteHelperResolver_safe_rails_application_routes -->|method_call| Rails
  Woods__Extractors__RouteHelperResolver_resolve_route_helper["Woods::Extractors::RouteHelperResolver#resolve_route_helper"]
  IGNORED_HELPER_PREFIXES["IGNORED_HELPER_PREFIXES"]
  Woods__Extractors__RouteHelperResolver_resolve_route_helper -->|method_call| IGNORED_HELPER_PREFIXES
  Woods__Extractors__RouteHelperResolver_extract_route_verb["Woods::Extractors::RouteHelperResolver#extract_route_verb"]
  Woods__Extractors__ScheduledJobExtractor["Woods::Extractors::ScheduledJobExtractor"]
  Woods__Extractors__ScheduledJobExtractor_initialize["Woods::Extractors::ScheduledJobExtractor#initialize"]
  SCHEDULE_FILES["SCHEDULE_FILES"]
  Woods__Extractors__ScheduledJobExtractor_initialize -->|method_call| SCHEDULE_FILES
  Woods__Extractors__ScheduledJobExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__ScheduledJobExtractor_initialize -->|method_call| Rails
  Woods__Extractors__ScheduledJobExtractor_initialize -->|method_call| File
  Woods__Extractors__ScheduledJobExtractor_extract_all["Woods::Extractors::ScheduledJobExtractor#extract_all"]
  Woods__Extractors__ScheduledJobExtractor_extract_scheduled_job_file["Woods::Extractors::ScheduledJobExtractor#extract_scheduled_job_file"]
  Woods__Extractors__ScheduledJobExtractor_extract_scheduled_job_file -->|method_call| Rails_logger
  Woods__Extractors__ScheduledJobExtractor_extract_scheduled_job_file -->|method_call| Rails
  Woods__Extractors__ScheduledJobExtractor_extract_yaml_schedule["Woods::Extractors::ScheduledJobExtractor#extract_yaml_schedule"]
  Woods__Extractors__ScheduledJobExtractor_extract_yaml_schedule -->|method_call| File
  Woods__Extractors__ScheduledJobExtractor_extract_yaml_schedule -->|method_call| YAML
  Woods__Extractors__ScheduledJobExtractor_unwrap_environment_nesting["Woods::Extractors::ScheduledJobExtractor#unwrap_environment_nesting"]
  ENVIRONMENT_KEYS["ENVIRONMENT_KEYS"]
  Woods__Extractors__ScheduledJobExtractor_unwrap_environment_nesting -->|method_call| ENVIRONMENT_KEYS
  Woods__Extractors__ScheduledJobExtractor_build_yaml_unit["Woods::Extractors::ScheduledJobExtractor#build_yaml_unit"]
  Woods__Extractors__ScheduledJobExtractor_build_yaml_unit -->|method_call| ExtractedUnit
  Woods__Extractors__ScheduledJobExtractor_extract_cron["Woods::Extractors::ScheduledJobExtractor#extract_cron"]
  Woods__Extractors__ScheduledJobExtractor_extract_whenever_schedule["Woods::Extractors::ScheduledJobExtractor#extract_whenever_schedule"]
  Woods__Extractors__ScheduledJobExtractor_extract_whenever_schedule -->|method_call| File
  Woods__Extractors__ScheduledJobExtractor_parse_whenever_blocks["Woods::Extractors::ScheduledJobExtractor#parse_whenever_blocks"]
  Woods__Extractors__ScheduledJobExtractor_detect_whenever_command["Woods::Extractors::ScheduledJobExtractor#detect_whenever_command"]
  Woods__Extractors__ScheduledJobExtractor_detect_whenever_command -->|method_call| Regexp
  Woods__Extractors__ScheduledJobExtractor_extract_job_class_from_runner["Woods::Extractors::ScheduledJobExtractor#extract_job_class_from_runner"]
  Woods__Extractors__ScheduledJobExtractor_build_whenever_unit["Woods::Extractors::ScheduledJobExtractor#build_whenever_unit"]
  Woods__Extractors__ScheduledJobExtractor_build_whenever_unit -->|method_call| ExtractedUnit
  Woods__Extractors__ScheduledJobExtractor_build_dependencies["Woods::Extractors::ScheduledJobExtractor#build_dependencies"]
  Woods__Extractors__ScheduledJobExtractor_humanize_frequency["Woods::Extractors::ScheduledJobExtractor#humanize_frequency"]
  CRON_HUMANIZE["CRON_HUMANIZE"]
  Woods__Extractors__ScheduledJobExtractor_humanize_frequency -->|method_call| CRON_HUMANIZE
  Woods__Extractors__SerializerExtractor["Woods::Extractors::SerializerExtractor"]
  Woods__Extractors__SerializerExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__SerializerExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__SerializerExtractor_initialize["Woods::Extractors::SerializerExtractor#initialize"]
  SERIALIZER_DIRECTORIES_map["SERIALIZER_DIRECTORIES.map"]
  Woods__Extractors__SerializerExtractor_initialize -->|method_call| SERIALIZER_DIRECTORIES_map
  SERIALIZER_DIRECTORIES["SERIALIZER_DIRECTORIES"]
  Woods__Extractors__SerializerExtractor_initialize -->|method_call| SERIALIZER_DIRECTORIES
  Woods__Extractors__SerializerExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__SerializerExtractor_initialize -->|method_call| Rails
  Woods__Extractors__SerializerExtractor_extract_all["Woods::Extractors::SerializerExtractor#extract_all"]
  BASE_CLASSES["BASE_CLASSES"]
  Woods__Extractors__SerializerExtractor_extract_all -->|method_call| BASE_CLASSES
  Woods__Extractors__SerializerExtractor_extract_serializer_file["Woods::Extractors::SerializerExtractor#extract_serializer_file"]
  Woods__Extractors__SerializerExtractor_extract_serializer_file -->|method_call| File
  Woods__Extractors__SerializerExtractor_extract_serializer_file -->|method_call| ExtractedUnit
  Woods__Extractors__SerializerExtractor_extract_serializer_file -->|method_call| Rails_logger
  Woods__Extractors__SerializerExtractor_extract_serializer_file -->|method_call| Rails
  Woods__Extractors__SerializerExtractor_extract_serializer_class["Woods::Extractors::SerializerExtractor#extract_serializer_class"]
  Woods__Extractors__SerializerExtractor_extract_serializer_class -->|method_call| File
  Woods__Extractors__SerializerExtractor_extract_serializer_class -->|method_call| ExtractedUnit
  Woods__Extractors__SerializerExtractor_extract_serializer_class -->|method_call| Rails_logger
  Woods__Extractors__SerializerExtractor_extract_serializer_class -->|method_call| Rails
  Woods__Extractors__SerializerExtractor_extract_class_name["Woods::Extractors::SerializerExtractor#extract_class_name"]
  Woods__Extractors__SerializerExtractor_serializer_file_["Woods::Extractors::SerializerExtractor#serializer_file?"]
  Woods__Extractors__SerializerExtractor_source_file_for["Woods::Extractors::SerializerExtractor#source_file_for"]
  Woods__Extractors__SerializerExtractor_source_file_for -->|method_call| Rails_root_join
  Woods__Extractors__SerializerExtractor_source_file_for -->|method_call| Rails_root
  Woods__Extractors__SerializerExtractor_source_file_for -->|method_call| Rails
  Woods__Extractors__SerializerExtractor_source_file_for -->|method_call| File
  Woods__Extractors__SerializerExtractor_annotate_source["Woods::Extractors::SerializerExtractor#annotate_source"]
  Woods__Extractors__SerializerExtractor_detect_serializer_type["Woods::Extractors::SerializerExtractor#detect_serializer_type"]
  Woods__Extractors__SerializerExtractor_detect_wrapped_model["Woods::Extractors::SerializerExtractor#detect_wrapped_model"]
  Woods__Extractors__SerializerExtractor_detect_wrapped_model -->|method_call| Regexp_last_match
  Woods__Extractors__SerializerExtractor_detect_wrapped_model -->|method_call| Regexp
  Woods__Extractors__SerializerExtractor_extract_metadata_from_source["Woods::Extractors::SerializerExtractor#extract_metadata_from_source"]
  Woods__Extractors__SerializerExtractor_extract_metadata_from_class["Woods::Extractors::SerializerExtractor#extract_metadata_from_class"]
  Woods__Extractors__SerializerExtractor_extract_attributes["Woods::Extractors::SerializerExtractor#extract_attributes"]
  Woods__Extractors__SerializerExtractor_extract_associations["Woods::Extractors::SerializerExtractor#extract_associations"]
  Woods__Extractors__SerializerExtractor_extract_custom_methods["Woods::Extractors::SerializerExtractor#extract_custom_methods"]
  Woods__Extractors__SerializerExtractor_extract_views["Woods::Extractors::SerializerExtractor#extract_views"]
  Woods__Extractors__SerializerExtractor_extract_dependencies["Woods::Extractors::SerializerExtractor#extract_dependencies"]
  Woods__Extractors__ServiceExtractor["Woods::Extractors::ServiceExtractor"]
  Woods__Extractors__ServiceExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__ServiceExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__ServiceExtractor -->|include| SourceNesting
  Woods__Extractors__ServiceExtractor_initialize["Woods::Extractors::ServiceExtractor#initialize"]
  SERVICE_DIRECTORIES_map["SERVICE_DIRECTORIES.map"]
  Woods__Extractors__ServiceExtractor_initialize -->|method_call| SERVICE_DIRECTORIES_map
  SERVICE_DIRECTORIES["SERVICE_DIRECTORIES"]
  Woods__Extractors__ServiceExtractor_initialize -->|method_call| SERVICE_DIRECTORIES
  Woods__Extractors__ServiceExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__ServiceExtractor_initialize -->|method_call| Rails
  Woods__Extractors__ServiceExtractor_extract_all["Woods::Extractors::ServiceExtractor#extract_all"]
  Woods__Extractors__ServiceExtractor_extract_service_file["Woods::Extractors::ServiceExtractor#extract_service_file"]
  Woods__Extractors__ServiceExtractor_extract_service_file -->|method_call| File
  Woods__Extractors__ServiceExtractor_extract_service_file -->|method_call| ExtractedUnit
  Woods__Extractors__ServiceExtractor_extract_service_file -->|method_call| Rails_logger
  Woods__Extractors__ServiceExtractor_extract_service_file -->|method_call| Rails
  Woods__Extractors__ServiceExtractor_annotate_source["Woods::Extractors::ServiceExtractor#annotate_source"]
  Woods__Extractors__ServiceExtractor_extract_metadata["Woods::Extractors::ServiceExtractor#extract_metadata"]
  Woods__Extractors__ServiceExtractor_extract_injected_deps["Woods::Extractors::ServiceExtractor#extract_injected_deps"]
  Woods__Extractors__ServiceExtractor_extract_rescue_handlers["Woods::Extractors::ServiceExtractor#extract_rescue_handlers"]
  Woods__Extractors__ServiceExtractor_infer_return_type["Woods::Extractors::ServiceExtractor#infer_return_type"]
  Woods__Extractors__ServiceExtractor_estimate_complexity["Woods::Extractors::ServiceExtractor#estimate_complexity"]
  Woods__Extractors__ServiceExtractor_infer_service_type["Woods::Extractors::ServiceExtractor#infer_service_type"]
  Woods__Extractors__ServiceExtractor_extract_dependencies["Woods::Extractors::ServiceExtractor#extract_dependencies"]
  Woods__Extractors__SharedDependencyScanner["Woods::Extractors::SharedDependencyScanner"]
  Woods__Extractors__SharedDependencyScanner_scan_model_dependencies["Woods::Extractors::SharedDependencyScanner#scan_model_dependencies"]
  Woods__Extractors__SharedDependencyScanner_scan_model_dependencies -->|method_call| Set
  Woods__Extractors__SharedDependencyScanner_scan_model_dependencies -->|method_call| ModelNameCache
  Woods__Extractors__SharedDependencyScanner_strip_ruby_line_comments["Woods::Extractors::SharedDependencyScanner#strip_ruby_line_comments"]
  Woods__Extractors__SharedDependencyScanner_strip_line_comment["Woods::Extractors::SharedDependencyScanner#strip_line_comment"]
  Woods__Extractors__SharedDependencyScanner_extract_constantize_targets["Woods::Extractors::SharedDependencyScanner#extract_constantize_targets"]
  Woods__Extractors__SharedDependencyScanner_extract_constantize_targets -->|method_call| ModelNameCache
  ModelNameCache_model_names["ModelNameCache.model_names"]
  Woods__Extractors__SharedDependencyScanner_extract_constantize_targets -->|method_call| ModelNameCache_model_names
  Woods__Extractors__SharedDependencyScanner_scan_service_dependencies["Woods::Extractors::SharedDependencyScanner#scan_service_dependencies"]
  Woods__Extractors__SharedDependencyScanner_scan_job_dependencies["Woods::Extractors::SharedDependencyScanner#scan_job_dependencies"]
  Woods__Extractors__SharedDependencyScanner_scan_mailer_dependencies["Woods::Extractors::SharedDependencyScanner#scan_mailer_dependencies"]
  Woods__Extractors__SharedDependencyScanner_scan_common_dependencies["Woods::Extractors::SharedDependencyScanner#scan_common_dependencies"]
  Woods__Extractors__SharedDependencyScanner_consolidate_dependencies["Woods::Extractors::SharedDependencyScanner#consolidate_dependencies"]
  Woods__Extractors__SharedDependencyScanner_scan_navigation_dependencies["Woods::Extractors::SharedDependencyScanner#scan_navigation_dependencies"]
  Woods__Extractors__SharedDependencyScanner_scan_navigation_dependencies -->|method_call| Woods_configuration
  Woods__Extractors__SharedDependencyScanner_scan_navigation_dependencies -->|method_call| Woods
  Woods__Extractors__SharedDependencyScanner_scan_navigation_dependencies -->|method_call| Set
  Woods__Extractors__SharedDependencyScanner_scan_form_dependencies["Woods::Extractors::SharedDependencyScanner#scan_form_dependencies"]
  Woods__Extractors__SharedDependencyScanner_scan_form_dependencies -->|method_call| Woods_configuration
  Woods__Extractors__SharedDependencyScanner_scan_form_dependencies -->|method_call| Woods
  Woods__Extractors__SharedDependencyScanner_scan_form_dependencies -->|method_call| Set
  Woods__Extractors__SharedUtilityMethods["Woods::Extractors::SharedUtilityMethods"]
  Woods__Extractors__SharedUtilityMethods -->|include| SourceNesting
  Woods__Extractors__SharedUtilityMethods_find_files_in_directories["Woods::Extractors::SharedUtilityMethods#find_files_in_directories"]
  Woods__Extractors__SharedUtilityMethods_find_files_in_directories -->|method_call| Dir
  Woods__Extractors__SharedUtilityMethods_app_source_["Woods::Extractors::SharedUtilityMethods#app_source?"]
  Woods__Extractors__SharedUtilityMethods_resolve_source_location["Woods::Extractors::SharedUtilityMethods#resolve_source_location"]
  Woods__Extractors__SharedUtilityMethods_resolve_source_location -->|method_call| Object
  Woods__Extractors__SharedUtilityMethods_resolve_source_location -->|method_call| Object_const_source_location
  Woods__Extractors__SharedUtilityMethods_extract_class_name["Woods::Extractors::SharedUtilityMethods#extract_class_name"]
  Woods__Extractors__SharedUtilityMethods_extract_parent_class["Woods::Extractors::SharedUtilityMethods#extract_parent_class"]
  Woods__Extractors__SharedUtilityMethods_count_loc["Woods::Extractors::SharedUtilityMethods#count_loc"]
  Woods__Extractors__SharedUtilityMethods_skip_file_["Woods::Extractors::SharedUtilityMethods#skip_file?"]
  Woods__Extractors__SharedUtilityMethods_extract_custom_errors["Woods::Extractors::SharedUtilityMethods#extract_custom_errors"]
  Woods__Extractors__SharedUtilityMethods_detect_entry_points["Woods::Extractors::SharedUtilityMethods#detect_entry_points"]
  Woods__Extractors__SharedUtilityMethods_extract_callback_conditions["Woods::Extractors::SharedUtilityMethods#extract_callback_conditions"]
  Woods__Extractors__SharedUtilityMethods_extract_action_filter_actions["Woods::Extractors::SharedUtilityMethods#extract_action_filter_actions"]
  Woods__Extractors__SharedUtilityMethods_condition_label["Woods::Extractors::SharedUtilityMethods#condition_label"]
  Woods__Extractors__SharedUtilityMethods_extract_namespace["Woods::Extractors::SharedUtilityMethods#extract_namespace"]
  Woods__Extractors__SharedUtilityMethods_extract_public_methods["Woods::Extractors::SharedUtilityMethods#extract_public_methods"]
  Woods__Extractors__SharedUtilityMethods_extract_public_methods -->|method_call| Regexp
  Woods__Extractors__SharedUtilityMethods_extract_class_methods["Woods::Extractors::SharedUtilityMethods#extract_class_methods"]
  Woods__Extractors__SharedUtilityMethods_extract_initialize_params["Woods::Extractors::SharedUtilityMethods#extract_initialize_params"]
  Woods__Extractors__SourceNesting["Woods::Extractors::SourceNesting"]
  Woods__Extractors__SourceNesting_qualified_first_class_name["Woods::Extractors::SourceNesting#qualified_first_class_name"]
  DECLARATION_PATTERN["DECLARATION_PATTERN"]
  Woods__Extractors__SourceNesting_qualified_first_class_name -->|method_call| DECLARATION_PATTERN
  Woods__Extractors__SourceNesting_qualified_outer_module_name["Woods::Extractors::SourceNesting#qualified_outer_module_name"]
  Woods__Extractors__SourceNesting_qualified_outer_module_name -->|method_call| DECLARATION_PATTERN
  MIXIN_INNER_MODULES["MIXIN_INNER_MODULES"]
  Woods__Extractors__SourceNesting_qualified_outer_module_name -->|method_call| MIXIN_INNER_MODULES
  Woods__Extractors__SourceNesting_block_opener_["Woods::Extractors::SourceNesting#block_opener?"]
  Woods__Extractors__SourceNesting_each_significant_line["Woods::Extractors::SourceNesting#each_significant_line"]
  Woods__Extractors__StateMachineExtractor["Woods::Extractors::StateMachineExtractor"]
  Woods__Extractors__StateMachineExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__StateMachineExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__StateMachineExtractor -->|include| SourceNesting
  Woods__Extractors__StateMachineExtractor_initialize["Woods::Extractors::StateMachineExtractor#initialize"]
  MODEL_DIRECTORIES_map["MODEL_DIRECTORIES.map"]
  Woods__Extractors__StateMachineExtractor_initialize -->|method_call| MODEL_DIRECTORIES_map
  MODEL_DIRECTORIES["MODEL_DIRECTORIES"]
  Woods__Extractors__StateMachineExtractor_initialize -->|method_call| MODEL_DIRECTORIES
  Woods__Extractors__StateMachineExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__StateMachineExtractor_initialize -->|method_call| Rails
  Woods__Extractors__StateMachineExtractor_extract_all["Woods::Extractors::StateMachineExtractor#extract_all"]
  Woods__Extractors__StateMachineExtractor_extract_model_file["Woods::Extractors::StateMachineExtractor#extract_model_file"]
  Woods__Extractors__StateMachineExtractor_extract_model_file -->|method_call| File
  Woods__Extractors__StateMachineExtractor_extract_model_file -->|method_call| Rails_logger
  Woods__Extractors__StateMachineExtractor_extract_model_file -->|method_call| Rails
  Woods__Extractors__StateMachineExtractor_detect_class_name["Woods::Extractors::StateMachineExtractor#detect_class_name"]
  Woods__Extractors__StateMachineExtractor_extract_aasm_units["Woods::Extractors::StateMachineExtractor#extract_aasm_units"]
  Woods__Extractors__StateMachineExtractor_parse_initial_state_aasm["Woods::Extractors::StateMachineExtractor#parse_initial_state_aasm"]
  Woods__Extractors__StateMachineExtractor_extract_statesman_units["Woods::Extractors::StateMachineExtractor#extract_statesman_units"]
  Woods__Extractors__StateMachineExtractor_parse_statesman_transitions["Woods::Extractors::StateMachineExtractor#parse_statesman_transitions"]
  Woods__Extractors__StateMachineExtractor_extract_state_machines_units["Woods::Extractors::StateMachineExtractor#extract_state_machines_units"]
  Woods__Extractors__StateMachineExtractor_extract_block_for_state_machine["Woods::Extractors::StateMachineExtractor#extract_block_for_state_machine"]
  Woods__Extractors__StateMachineExtractor_parse_state_machine_callbacks["Woods::Extractors::StateMachineExtractor#parse_state_machine_callbacks"]
  Woods__Extractors__StateMachineExtractor_parse_events_from_source["Woods::Extractors::StateMachineExtractor#parse_events_from_source"]
  Woods__Extractors__StateMachineExtractor_parse_transition_line["Woods::Extractors::StateMachineExtractor#parse_transition_line"]
  Woods__Extractors__StateMachineExtractor_build_unit["Woods::Extractors::StateMachineExtractor#build_unit"]
  Woods__Extractors__StateMachineExtractor_build_unit -->|method_call| ExtractedUnit
  Woods__Extractors__StateMachineExtractor_build_dependencies["Woods::Extractors::StateMachineExtractor#build_dependencies"]
  Woods__Extractors__TestMappingExtractor["Woods::Extractors::TestMappingExtractor"]
  Woods__Extractors__TestMappingExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__TestMappingExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__TestMappingExtractor_initialize["Woods::Extractors::TestMappingExtractor#initialize"]
  Woods__Extractors__TestMappingExtractor_initialize -->|method_call| Rails
  Woods__Extractors__TestMappingExtractor_extract_all["Woods::Extractors::TestMappingExtractor#extract_all"]
  Woods__Extractors__TestMappingExtractor_extract_test_file["Woods::Extractors::TestMappingExtractor#extract_test_file"]
  Woods__Extractors__TestMappingExtractor_extract_test_file -->|method_call| File
  Woods__Extractors__TestMappingExtractor_extract_test_file -->|method_call| ExtractedUnit
  Woods__Extractors__TestMappingExtractor_extract_test_file -->|method_call| Rails_logger
  Woods__Extractors__TestMappingExtractor_extract_test_file -->|method_call| Rails
  Woods__Extractors__TestMappingExtractor_rspec_units["Woods::Extractors::TestMappingExtractor#rspec_units"]
  Woods__Extractors__TestMappingExtractor_rspec_units -->|method_call| Dir___
  Woods__Extractors__TestMappingExtractor_minitest_units["Woods::Extractors::TestMappingExtractor#minitest_units"]
  Woods__Extractors__TestMappingExtractor_minitest_units -->|method_call| Dir___
  Woods__Extractors__TestMappingExtractor_detect_framework["Woods::Extractors::TestMappingExtractor#detect_framework"]
  Woods__Extractors__TestMappingExtractor_extract_metadata["Woods::Extractors::TestMappingExtractor#extract_metadata"]
  Woods__Extractors__TestMappingExtractor_extract_subject_class["Woods::Extractors::TestMappingExtractor#extract_subject_class"]
  Woods__Extractors__TestMappingExtractor_extract_rspec_subject["Woods::Extractors::TestMappingExtractor#extract_rspec_subject"]
  Woods__Extractors__TestMappingExtractor_extract_minitest_subject["Woods::Extractors::TestMappingExtractor#extract_minitest_subject"]
  Woods__Extractors__TestMappingExtractor_count_tests["Woods::Extractors::TestMappingExtractor#count_tests"]
  Woods__Extractors__TestMappingExtractor_extract_shared_examples_defined["Woods::Extractors::TestMappingExtractor#extract_shared_examples_defined"]
  Woods__Extractors__TestMappingExtractor_extract_shared_examples_used["Woods::Extractors::TestMappingExtractor#extract_shared_examples_used"]
  Woods__Extractors__TestMappingExtractor_infer_test_type["Woods::Extractors::TestMappingExtractor#infer_test_type"]
  Woods__Extractors__TestMappingExtractor_extract_dependencies["Woods::Extractors::TestMappingExtractor#extract_dependencies"]
  Woods__Extractors__TestMappingExtractor_infer_type_from_test_type["Woods::Extractors::TestMappingExtractor#infer_type_from_test_type"]
  Woods__Extractors__ValidatorExtractor["Woods::Extractors::ValidatorExtractor"]
  Woods__Extractors__ValidatorExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__ValidatorExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__ValidatorExtractor_initialize["Woods::Extractors::ValidatorExtractor#initialize"]
  VALIDATOR_DIRECTORIES_map["VALIDATOR_DIRECTORIES.map"]
  Woods__Extractors__ValidatorExtractor_initialize -->|method_call| VALIDATOR_DIRECTORIES_map
  VALIDATOR_DIRECTORIES["VALIDATOR_DIRECTORIES"]
  Woods__Extractors__ValidatorExtractor_initialize -->|method_call| VALIDATOR_DIRECTORIES
  Woods__Extractors__ValidatorExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__ValidatorExtractor_initialize -->|method_call| Rails
  Woods__Extractors__ValidatorExtractor_extract_all["Woods::Extractors::ValidatorExtractor#extract_all"]
  Woods__Extractors__ValidatorExtractor_extract_validator_file["Woods::Extractors::ValidatorExtractor#extract_validator_file"]
  Woods__Extractors__ValidatorExtractor_extract_validator_file -->|method_call| File
  Woods__Extractors__ValidatorExtractor_extract_validator_file -->|method_call| ExtractedUnit
  Woods__Extractors__ValidatorExtractor_extract_validator_file -->|method_call| Rails_logger
  Woods__Extractors__ValidatorExtractor_extract_validator_file -->|method_call| Rails
  Woods__Extractors__ValidatorExtractor_validator_file_["Woods::Extractors::ValidatorExtractor#validator_file?"]
  Woods__Extractors__ValidatorExtractor_annotate_source["Woods::Extractors::ValidatorExtractor#annotate_source"]
  Woods__Extractors__ValidatorExtractor_extract_metadata["Woods::Extractors::ValidatorExtractor#extract_metadata"]
  Woods__Extractors__ValidatorExtractor_detect_validator_type["Woods::Extractors::ValidatorExtractor#detect_validator_type"]
  Woods__Extractors__ValidatorExtractor_extract_validated_attributes["Woods::Extractors::ValidatorExtractor#extract_validated_attributes"]
  Woods__Extractors__ValidatorExtractor_extract_validation_rules["Woods::Extractors::ValidatorExtractor#extract_validation_rules"]
  Woods__Extractors__ValidatorExtractor_extract_error_messages["Woods::Extractors::ValidatorExtractor#extract_error_messages"]
  Woods__Extractors__ValidatorExtractor_extract_options["Woods::Extractors::ValidatorExtractor#extract_options"]
  Woods__Extractors__ValidatorExtractor_infer_models_from_name["Woods::Extractors::ValidatorExtractor#infer_models_from_name"]
  Woods__Extractors__ValidatorExtractor_extract_dependencies["Woods::Extractors::ValidatorExtractor#extract_dependencies"]
  Woods__Extractors__ViewComponentExtractor["Woods::Extractors::ViewComponentExtractor"]
  Woods__Extractors__ViewComponentExtractor -->|include| SharedUtilityMethods
  Woods__Extractors__ViewComponentExtractor -->|include| SharedDependencyScanner
  Woods__Extractors__ViewComponentExtractor -->|include| RouteHelperResolver
  Woods__Extractors__ViewComponentExtractor_initialize["Woods::Extractors::ViewComponentExtractor#initialize"]
  Woods__Extractors__ViewComponentExtractor_extract_all["Woods::Extractors::ViewComponentExtractor#extract_all"]
  Woods__Extractors__ViewComponentExtractor_discoverable_classes["Woods::Extractors::ViewComponentExtractor#discoverable_classes"]
  Woods__Extractors__ViewComponentExtractor_extract_component["Woods::Extractors::ViewComponentExtractor#extract_component"]
  Woods__Extractors__ViewComponentExtractor_extract_component -->|method_call| ExtractedUnit
  Woods__Extractors__ViewComponentExtractor_extract_component -->|method_call| Rails_logger
  Woods__Extractors__ViewComponentExtractor_extract_component -->|method_call| Rails
  Woods__Extractors__ViewComponentExtractor_find_component_base["Woods::Extractors::ViewComponentExtractor#find_component_base"]
  Woods__Extractors__ViewComponentExtractor_preview_class_["Woods::Extractors::ViewComponentExtractor#preview_class?"]
  Woods__Extractors__ViewComponentExtractor_source_file_for["Woods::Extractors::ViewComponentExtractor#source_file_for"]
  Woods__Extractors__ViewComponentExtractor_source_file_for -->|method_call| Rails_root
  Woods__Extractors__ViewComponentExtractor_source_file_for -->|method_call| Rails
  Woods__Extractors__ViewComponentExtractor_source_file_for -->|method_call| File
  Woods__Extractors__ViewComponentExtractor_read_source["Woods::Extractors::ViewComponentExtractor#read_source"]
  Woods__Extractors__ViewComponentExtractor_read_source -->|method_call| File
  Woods__Extractors__ViewComponentExtractor_extract_metadata["Woods::Extractors::ViewComponentExtractor#extract_metadata"]
  Woods__Extractors__ViewComponentExtractor_extract_slots["Woods::Extractors::ViewComponentExtractor#extract_slots"]
  Woods__Extractors__ViewComponentExtractor_extract_renders_many["Woods::Extractors::ViewComponentExtractor#extract_renders_many"]
  Woods__Extractors__ViewComponentExtractor_extract_renders_one["Woods::Extractors::ViewComponentExtractor#extract_renders_one"]
  Woods__Extractors__ViewComponentExtractor_extract_initialize_params["Woods::Extractors::ViewComponentExtractor#extract_initialize_params"]
  Woods__Extractors__ViewComponentExtractor_detect_sidecar_template["Woods::Extractors::ViewComponentExtractor#detect_sidecar_template"]
  Woods__Extractors__ViewComponentExtractor_detect_sidecar_template -->|method_call| Rails_root
  Woods__Extractors__ViewComponentExtractor_detect_sidecar_template -->|method_call| Rails
  Woods__Extractors__ViewComponentExtractor_detect_sidecar_template -->|method_call| File
  Woods__Extractors__ViewComponentExtractor_detect_preview_class["Woods::Extractors::ViewComponentExtractor#detect_preview_class"]
  Woods__Extractors__ViewComponentExtractor_detect_collection_support["Woods::Extractors::ViewComponentExtractor#detect_collection_support"]
  Woods__Extractors__ViewComponentExtractor_extract_callbacks["Woods::Extractors::ViewComponentExtractor#extract_callbacks"]
  Woods__Extractors__ViewComponentExtractor_extract_content_areas["Woods::Extractors::ViewComponentExtractor#extract_content_areas"]
  Woods__Extractors__ViewComponentExtractor_extract_dependencies["Woods::Extractors::ViewComponentExtractor#extract_dependencies"]
  Woods__Extractors__ViewEngines["Woods::Extractors::ViewEngines"]
  Woods__Extractors__ViewEngines__Base["Woods::Extractors::ViewEngines::Base"]
  Woods__Extractors__ViewEngines__Base_name["Woods::Extractors::ViewEngines::Base#name"]
  Woods__Extractors__ViewEngines__Base_extensions["Woods::Extractors::ViewEngines::Base#extensions"]
  Woods__Extractors__ViewEngines__Base_handles_["Woods::Extractors::ViewEngines::Base#handles?"]
  Woods__Extractors__ViewEngines__Base_parse["Woods::Extractors::ViewEngines::Base#parse"]
  Woods__Extractors__ViewEngines__Base_scan_partials["Woods::Extractors::ViewEngines::Base#scan_partials"]
  Woods__Extractors__ViewEngines__Base_scan_instance_variables["Woods::Extractors::ViewEngines::Base#scan_instance_variables"]
  Woods__Extractors__ViewEngines__Base_scan_helpers["Woods::Extractors::ViewEngines::Base#scan_helpers"]
  Woods__Extractors__ViewEngines__Base_resolve_partial_identifier["Woods::Extractors::ViewEngines::Base#resolve_partial_identifier"]
  Woods__Extractors__ViewEngines__Base_scan_navigation_candidates["Woods::Extractors::ViewEngines::Base#scan_navigation_candidates"]
  Woods__Extractors__ViewEngines__Erb["Woods::Extractors::ViewEngines::Erb"]
  Base["Base"]
  Woods__Extractors__ViewEngines__Erb -->|inheritance| Base
  Woods__Extractors__ViewEngines__Erb_name["Woods::Extractors::ViewEngines::Erb#name"]
  Woods__Extractors__ViewEngines__Erb_extensions["Woods::Extractors::ViewEngines::Erb#extensions"]
  Woods__Extractors__ViewEngines__Erb_scan_partials["Woods::Extractors::ViewEngines::Erb#scan_partials"]
  Woods__Extractors__ViewEngines__Erb_scan_partials -->|method_call| Set
  RESERVED_RENDER_OPTIONS["RESERVED_RENDER_OPTIONS"]
  Woods__Extractors__ViewEngines__Erb_scan_partials -->|method_call| RESERVED_RENDER_OPTIONS
  Woods__Extractors__ViewEngines__Erb_scan_instance_variables["Woods::Extractors::ViewEngines::Erb#scan_instance_variables"]
  Woods__Extractors__ViewEngines__Erb_scan_helpers["Woods::Extractors::ViewEngines::Erb#scan_helpers"]
  Woods__Extractors__ViewEngines__Erb_scan_helpers -->|method_call| Set
  COMMON_HELPERS["COMMON_HELPERS"]
  Woods__Extractors__ViewEngines__Erb_scan_helpers -->|method_call| COMMON_HELPERS
  Woods__Extractors__ViewEngines__Erb_resolve_partial_identifier["Woods::Extractors::ViewEngines::Erb#resolve_partial_identifier"]
  Woods__Extractors__ViewEngines__Erb_resolve_partial_identifier -->|method_call| File
  Woods__Extractors__ViewEngines__Erb_scan_navigation_candidates["Woods::Extractors::ViewEngines::Erb#scan_navigation_candidates"]
  Woods__Extractors__ViewTemplateExtractor["Woods::Extractors::ViewTemplateExtractor"]
  Woods__Extractors__ViewTemplateExtractor -->|include| RouteHelperResolver
  Woods__Extractors__ViewTemplateExtractor_supported_template_engines["Woods::Extractors::ViewTemplateExtractor.supported_template_engines"]
  ENGINES_map_uniq["ENGINES.map.uniq"]
  Woods__Extractors__ViewTemplateExtractor_supported_template_engines -->|method_call| ENGINES_map_uniq
  ENGINES_map["ENGINES.map"]
  Woods__Extractors__ViewTemplateExtractor_supported_template_engines -->|method_call| ENGINES_map
  ENGINES["ENGINES"]
  Woods__Extractors__ViewTemplateExtractor_supported_template_engines -->|method_call| ENGINES
  Woods__Extractors__ViewTemplateExtractor_initialize["Woods::Extractors::ViewTemplateExtractor#initialize"]
  VIEW_DIRECTORIES_map["VIEW_DIRECTORIES.map"]
  Woods__Extractors__ViewTemplateExtractor_initialize -->|method_call| VIEW_DIRECTORIES_map
  VIEW_DIRECTORIES["VIEW_DIRECTORIES"]
  Woods__Extractors__ViewTemplateExtractor_initialize -->|method_call| VIEW_DIRECTORIES
  Woods__Extractors__ViewTemplateExtractor_initialize -->|method_call| Rails_root
  Woods__Extractors__ViewTemplateExtractor_initialize -->|method_call| Rails
  Woods__Extractors__ViewTemplateExtractor_initialize -->|method_call| ENGINES
  Woods__Extractors__ViewTemplateExtractor_extract_all["Woods::Extractors::ViewTemplateExtractor#extract_all"]
  Woods__Extractors__ViewTemplateExtractor_extract_all -->|method_call| Dir
  Woods__Extractors__ViewTemplateExtractor_extract_view_template_file["Woods::Extractors::ViewTemplateExtractor#extract_view_template_file"]
  Woods__Extractors__ViewTemplateExtractor_extract_view_template_file -->|method_call| File
  Woods__Extractors__ViewTemplateExtractor_extract_view_template_file -->|method_call| ExtractedUnit
  Woods__Extractors__ViewTemplateExtractor_extract_view_template_file -->|method_call| Rails_logger
  Woods__Extractors__ViewTemplateExtractor_extract_view_template_file -->|method_call| Rails
  Woods__Extractors__ViewTemplateExtractor_engine_for["Woods::Extractors::ViewTemplateExtractor#engine_for"]
  Woods__Extractors__ViewTemplateExtractor_build_identifier["Woods::Extractors::ViewTemplateExtractor#build_identifier"]
  Woods__Extractors__ViewTemplateExtractor_extract_view_namespace["Woods::Extractors::ViewTemplateExtractor#extract_view_namespace"]
  Woods__Extractors__ViewTemplateExtractor_extract_view_namespace -->|method_call| File
  Woods__Extractors__ViewTemplateExtractor_build_metadata["Woods::Extractors::ViewTemplateExtractor#build_metadata"]
  Woods__Extractors__ViewTemplateExtractor_partial_["Woods::Extractors::ViewTemplateExtractor#partial?"]
  Woods__Extractors__ViewTemplateExtractor_partial_ -->|method_call| File_basename
  Woods__Extractors__ViewTemplateExtractor_partial_ -->|method_call| File
  Woods__Extractors__ViewTemplateExtractor_build_dependencies["Woods::Extractors::ViewTemplateExtractor#build_dependencies"]
  Woods__Extractors__ViewTemplateExtractor_resolve_navigation_candidates["Woods::Extractors::ViewTemplateExtractor#resolve_navigation_candidates"]
  Woods__Extractors__ViewTemplateExtractor_resolve_navigation_candidates -->|method_call| Woods_configuration
  Woods__Extractors__ViewTemplateExtractor_resolve_navigation_candidates -->|method_call| Woods
  Woods__Extractors__ViewTemplateExtractor_resolve_navigation_candidates -->|method_call| Set
  Woods__Extractors__ViewTemplateExtractor_infer_controller["Woods::Extractors::ViewTemplateExtractor#infer_controller"]
  Woods__Feedback["Woods::Feedback"]
  Woods__Feedback__GapDetector["Woods::Feedback::GapDetector"]
  Woods__Feedback__GapDetector_initialize["Woods::Feedback::GapDetector#initialize"]
  Woods__Feedback__GapDetector_detect["Woods::Feedback::GapDetector#detect"]
  Woods__Feedback__GapDetector_detect_low_score_patterns["Woods::Feedback::GapDetector#detect_low_score_patterns"]
  Woods__Feedback__GapDetector_count_keywords["Woods::Feedback::GapDetector#count_keywords"]
  Woods__Feedback__GapDetector_count_keywords -->|method_call| Hash
  Woods__Feedback__GapDetector_detect_frequently_missing["Woods::Feedback::GapDetector#detect_frequently_missing"]
  Woods__Feedback__GapDetector_detect_frequently_missing -->|method_call| Hash
  Woods__Feedback__Store["Woods::Feedback::Store"]
  Woods__Feedback__Store_initialize["Woods::Feedback::Store#initialize"]
  Woods__Feedback__Store_record_rating["Woods::Feedback::Store#record_rating"]
  Woods__Feedback__Store_record_gap["Woods::Feedback::Store#record_gap"]
  Woods__Feedback__Store_all_entries["Woods::Feedback::Store#all_entries"]
  Woods__Feedback__Store_all_entries -->|method_call| File
  Woods__Feedback__Store_all_entries -->|method_call| JSON
  Woods__Feedback__Store_ratings["Woods::Feedback::Store#ratings"]
  Woods__Feedback__Store_gaps["Woods::Feedback::Store#gaps"]
  Woods__Feedback__Store_average_score["Woods::Feedback::Store#average_score"]
  Woods__Feedback__Store_append["Woods::Feedback::Store#append"]
  Woods__Feedback__Store_append -->|method_call| FileUtils
  Woods__Feedback__Store_append -->|method_call| File
  Woods__FilenameUtils["Woods::FilenameUtils"]
  Woods__FilenameUtils_safe_segment["Woods::FilenameUtils.safe_segment"]
  Woods__FilenameUtils_flow_filename["Woods::FilenameUtils.flow_filename"]
  Woods__FilenameUtils_flow_filename -->|method_call| Digest__SHA256_hexdigest
  Woods__FilenameUtils_flow_filename -->|method_call| Digest__SHA256
  Woods__FilenameUtils_lossy_segment_["Woods::FilenameUtils.lossy_segment?"]
  Woods__FilenameUtils_safe_filename["Woods::FilenameUtils#safe_filename"]
  Woods__FilenameUtils_collision_safe_filename["Woods::FilenameUtils#collision_safe_filename"]
  Woods__FilenameUtils_collision_safe_filename -->|method_call| FilenameUtils
  Woods__FilenameUtils_collision_safe_filename -->|method_call| Digest__SHA256_hexdigest
  Woods__FilenameUtils_collision_safe_filename -->|method_call| Digest__SHA256
  Woods__FlowAnalysis["Woods::FlowAnalysis"]
  Woods__FlowAnalysis__OperationExtractor["Woods::FlowAnalysis::OperationExtractor"]
  Woods__FlowAnalysis__OperationExtractor_extract["Woods::FlowAnalysis::OperationExtractor#extract"]
  Woods__FlowAnalysis__OperationExtractor_walk["Woods::FlowAnalysis::OperationExtractor#walk"]
  Woods__FlowAnalysis__OperationExtractor_walk_children["Woods::FlowAnalysis::OperationExtractor#walk_children"]
  Woods__FlowAnalysis__OperationExtractor_handle_block["Woods::FlowAnalysis::OperationExtractor#handle_block"]
  Woods__FlowAnalysis__OperationExtractor_handle_send["Woods::FlowAnalysis::OperationExtractor#handle_send"]
  Woods__FlowAnalysis__OperationExtractor_handle_conditional["Woods::FlowAnalysis::OperationExtractor#handle_conditional"]
  Woods__FlowAnalysis__OperationExtractor_handle_case["Woods::FlowAnalysis::OperationExtractor#handle_case"]
  Woods__FlowAnalysis__OperationExtractor_condition_source["Woods::FlowAnalysis::OperationExtractor#condition_source"]
  Woods__FlowAnalysis__OperationExtractor_transaction_call_["Woods::FlowAnalysis::OperationExtractor#transaction_call?"]
  TRANSACTION_METHODS["TRANSACTION_METHODS"]
  Woods__FlowAnalysis__OperationExtractor_transaction_call_ -->|method_call| TRANSACTION_METHODS
  Woods__FlowAnalysis__OperationExtractor_async_call_["Woods::FlowAnalysis::OperationExtractor#async_call?"]
  ASYNC_METHODS["ASYNC_METHODS"]
  Woods__FlowAnalysis__OperationExtractor_async_call_ -->|method_call| ASYNC_METHODS
  Woods__FlowAnalysis__OperationExtractor_response_call_["Woods::FlowAnalysis::OperationExtractor#response_call?"]
  RESPONSE_METHODS["RESPONSE_METHODS"]
  Woods__FlowAnalysis__OperationExtractor_response_call_ -->|method_call| RESPONSE_METHODS
  Woods__FlowAnalysis__OperationExtractor_dynamic_dispatch_["Woods::FlowAnalysis::OperationExtractor#dynamic_dispatch?"]
  DYNAMIC_DISPATCH_METHODS["DYNAMIC_DISPATCH_METHODS"]
  Woods__FlowAnalysis__OperationExtractor_dynamic_dispatch_ -->|method_call| DYNAMIC_DISPATCH_METHODS
  Woods__FlowAnalysis__OperationExtractor_significant_call_["Woods::FlowAnalysis::OperationExtractor#significant_call?"]
  Ast__INSIGNIFICANT_METHODS["Ast::INSIGNIFICANT_METHODS"]
  Woods__FlowAnalysis__OperationExtractor_significant_call_ -->|method_call| Ast__INSIGNIFICANT_METHODS
  Woods__FlowAnalysis__ResponseCodeMapper["Woods::FlowAnalysis::ResponseCodeMapper"]
  Woods__FlowAnalysis__ResponseCodeMapper_resolve_method["Woods::FlowAnalysis::ResponseCodeMapper.resolve_method"]
  STATUS_CODES["STATUS_CODES"]
  Woods__FlowAnalysis__ResponseCodeMapper_resolve_method -->|method_call| STATUS_CODES
  Woods__FlowAnalysis__ResponseCodeMapper_resolve_status["Woods::FlowAnalysis::ResponseCodeMapper.resolve_status"]
  Woods__FlowAnalysis__ResponseCodeMapper_resolve_status -->|method_call| STATUS_CODES
  Woods__FlowAnalysis__ResponseCodeMapper_extract_status_from_args["Woods::FlowAnalysis::ResponseCodeMapper.extract_status_from_args"]
  Woods__FlowAssembler["Woods::FlowAssembler"]
  Woods__FlowAssembler_initialize["Woods::FlowAssembler#initialize"]
  Woods__FlowAssembler_initialize -->|method_call| Ast__Parser
  Woods__FlowAssembler_initialize -->|method_call| Ast__MethodExtractor
  Woods__FlowAssembler_initialize -->|method_call| FlowAnalysis__OperationExtractor
  Woods__FlowAssembler_assemble["Woods::FlowAssembler#assemble"]
  Woods__FlowAssembler_assemble -->|method_call| Set
  FlowDocument["FlowDocument"]
  Woods__FlowAssembler_assemble -->|method_call| FlowDocument
  Woods__FlowAssembler_expand["Woods::FlowAssembler#expand"]
  Woods__FlowAssembler_extract_operations["Woods::FlowAssembler#extract_operations"]
  Woods__FlowAssembler_prepend_callbacks["Woods::FlowAssembler#prepend_callbacks"]
  Woods__FlowAssembler_expand_operation["Woods::FlowAssembler#expand_operation"]
  Woods__FlowAssembler_resolve_target["Woods::FlowAssembler#resolve_target"]
  Woods__FlowAssembler_compute_resolved_target["Woods::FlowAssembler#compute_resolved_target"]
  Woods__FlowAssembler_parse_identifier["Woods::FlowAssembler#parse_identifier"]
  Woods__FlowAssembler_load_unit["Woods::FlowAssembler#load_unit"]
  Woods__FlowAssembler_load_unit -->|method_call| Digest__SHA256_hexdigest
  Woods__FlowAssembler_load_unit -->|method_call| Digest__SHA256
  Woods__FlowAssembler_load_unit -->|method_call| Dir___
  Woods__FlowAssembler_load_unit -->|method_call| JSON
  Woods__FlowAssembler_extract_route["Woods::FlowAssembler#extract_route"]
  Woods__FlowAssembler_resolve_route_entry["Woods::FlowAssembler#resolve_route_entry"]
  Woods__FlowAssembler_resolve_route_entry -->|method_call| Array
  Woods__FlowDocument["Woods::FlowDocument"]
  Woods__FlowDocument_initialize["Woods::FlowDocument#initialize"]
  Woods__FlowDocument_initialize -->|method_call| Time_now
  Woods__FlowDocument_initialize -->|method_call| Time
  Woods__FlowDocument_to_h["Woods::FlowDocument#to_h"]
  Woods__FlowDocument_from_h["Woods::FlowDocument.from_h"]
  Woods__FlowDocument_deep_symbolize_keys["Woods::FlowDocument.deep_symbolize_keys"]
  Woods__FlowDocument_to_markdown["Woods::FlowDocument#to_markdown"]
  Woods__FlowDocument_format_header["Woods::FlowDocument#format_header"]
  Woods__FlowDocument_format_step["Woods::FlowDocument#format_step"]
  Woods__FlowDocument_format_operations["Woods::FlowDocument#format_operations"]
  Woods__FlowPrecomputer["Woods::FlowPrecomputer"]
  Woods__FlowPrecomputer_initialize["Woods::FlowPrecomputer#initialize"]
  Woods__FlowPrecomputer_initialize -->|method_call| File
  Woods__FlowPrecomputer_precompute["Woods::FlowPrecomputer#precompute"]
  Woods__FlowPrecomputer_precompute -->|method_call| FileUtils
  FlowAssembler["FlowAssembler"]
  Woods__FlowPrecomputer_precompute -->|method_call| FlowAssembler
  Woods__FlowPrecomputer_controller_units["Woods::FlowPrecomputer#controller_units"]
  Woods__FlowPrecomputer_assemble_and_write["Woods::FlowPrecomputer#assemble_and_write"]
  Woods__FlowPrecomputer_assemble_and_write -->|method_call| Woods__FilenameUtils
  Woods__FlowPrecomputer_assemble_and_write -->|method_call| Woods__AtomicFile
  Woods__FlowPrecomputer_assemble_and_write -->|method_call| File
  Woods__FlowPrecomputer_assemble_and_write -->|method_call| Rails_logger
  Woods__FlowPrecomputer_assemble_and_write -->|method_call| Rails
  Woods__FlowPrecomputer_write_flow_index["Woods::FlowPrecomputer#write_flow_index"]
  Woods__FlowPrecomputer_write_flow_index -->|method_call| File
  Woods__FlowPrecomputer_write_flow_index -->|method_call| Woods__AtomicFile
  Woods__FlowPrecomputer_canonical_json["Woods::FlowPrecomputer#canonical_json"]
  Woods__FlowPrecomputer_canonical_json -->|method_call| JSON
  Woods__FlowPrecomputer_sort_keys_deep["Woods::FlowPrecomputer#sort_keys_deep"]
  Woods__Formatting["Woods::Formatting"]
  Woods__Formatting__Base["Woods::Formatting::Base"]
  Woods__Formatting__Base_format["Woods::Formatting::Base#format"]
  Woods__Formatting__HumanAdapter["Woods::Formatting::HumanAdapter"]
  Woods__Formatting__HumanAdapter -->|inheritance| Base
  Woods__Formatting__HumanAdapter_format["Woods::Formatting::HumanAdapter#format"]
  Woods__Formatting__HumanAdapter_format_header["Woods::Formatting::HumanAdapter#format_header"]
  Woods__Formatting__HumanAdapter_format_sources["Woods::Formatting::HumanAdapter#format_sources"]
  Woods__Formatting__HumanAdapter_format_source_entry["Woods::Formatting::HumanAdapter#format_source_entry"]
  Woods__Generation_initialize["Woods::Generation#initialize"]
  Woods__Generation_initialize -->|method_call| File
  Woods__Generation_current["Woods::Generation#current"]
  Woods__Generation_current -->|method_call| File
  Woods__Generation_current -->|method_call| JSON
  Marker["Marker"]
  Woods__Generation_current -->|method_call| Marker
  Woods__Generation_bump_["Woods::Generation#bump!"]
  Woods__Generation_bump_ -->|method_call| Marker
  Woods__Generation_bump_ -->|method_call| AtomicFile
  Woods__Generation_payload_dir["Woods::Generation#payload_dir"]
  Woods__Generation_root["Woods::Generation#root"]
  Woods__Generation_root -->|method_call| Pathname
  Woods__GitProvenance["Woods::GitProvenance"]
  Woods__GitProvenance_initialize["Woods::GitProvenance#initialize"]
  Woods__GitProvenance_branch["Woods::GitProvenance#branch"]
  Woods__GitProvenance_sha["Woods::GitProvenance#sha"]
  Woods__GitProvenance_to_h["Woods::GitProvenance#to_h"]
  Woods__GitProvenance_present_["Woods::GitProvenance#present?"]
  Woods__GitProvenance_rev_parse["Woods::GitProvenance#rev_parse"]
  Woods__GitProvenance_rev_parse -->|method_call| Open3
  Woods__GitProvenance_fallback["Woods::GitProvenance#fallback"]
  Woods__GitProvenance_git_available_["Woods::GitProvenance#git_available?"]
  Woods__GitProvenance_git_available_ -->|method_call| Open3
  Woods__GitProvenance_git_working_tree_["Woods::GitProvenance#git_working_tree?"]
  Woods__GitProvenance_git_working_tree_ -->|method_call| File
  Woods__GraphAnalyzer["Woods::GraphAnalyzer"]
  Woods__GraphAnalyzer_initialize["Woods::GraphAnalyzer#initialize"]
  Woods__GraphAnalyzer_orphans["Woods::GraphAnalyzer#orphans"]
  EXCLUDED_ORPHAN_TYPES["EXCLUDED_ORPHAN_TYPES"]
  Woods__GraphAnalyzer_orphans -->|method_call| EXCLUDED_ORPHAN_TYPES
  Woods__GraphAnalyzer_dead_ends["Woods::GraphAnalyzer#dead_ends"]
  Woods__GraphAnalyzer_hubs["Woods::GraphAnalyzer#hubs"]
  Woods__GraphAnalyzer_cycles["Woods::GraphAnalyzer#cycles"]
  Woods__GraphAnalyzer_bridges["Woods::GraphAnalyzer#bridges"]
  Woods__GraphAnalyzer_bridges -->|method_call| Hash
  Woods__GraphAnalyzer_bridges -->|method_call| Random
  Woods__GraphAnalyzer_domain_clusters["Woods::GraphAnalyzer#domain_clusters"]
  Woods__GraphAnalyzer_analyze["Woods::GraphAnalyzer#analyze"]
  Woods__GraphAnalyzer_cluster_prefix["Woods::GraphAnalyzer#cluster_prefix"]
  Woods__GraphAnalyzer_seed_namespace_clusters["Woods::GraphAnalyzer#seed_namespace_clusters"]
  Woods__GraphAnalyzer_assign_orphaned_units["Woods::GraphAnalyzer#assign_orphaned_units"]
  Woods__GraphAnalyzer_find_most_connected_cluster["Woods::GraphAnalyzer#find_most_connected_cluster"]
  Woods__GraphAnalyzer_find_most_connected_cluster -->|method_call| Hash
  Woods__GraphAnalyzer_merge_small_clusters["Woods::GraphAnalyzer#merge_small_clusters"]
  Woods__GraphAnalyzer_find_merge_target["Woods::GraphAnalyzer#find_merge_target"]
  Woods__GraphAnalyzer_find_merge_target -->|method_call| Hash
  Woods__GraphAnalyzer_enrich_clusters["Woods::GraphAnalyzer#enrich_clusters"]
  Woods__GraphAnalyzer_enrich_clusters -->|method_call| Set
  Woods__GraphAnalyzer_graph_data["Woods::GraphAnalyzer#graph_data"]
  Woods__GraphAnalyzer_graph_nodes["Woods::GraphAnalyzer#graph_nodes"]
  Woods__GraphAnalyzer_detect_cycles["Woods::GraphAnalyzer#detect_cycles"]
  Woods__GraphAnalyzer_detect_cycles -->|method_call| Hash
  Woods__GraphAnalyzer_detect_cycles -->|method_call| Set
  Woods__GraphAnalyzer_extract_cycle_from_path["Woods::GraphAnalyzer#extract_cycle_from_path"]
  Woods__GraphAnalyzer_normalize_cycle_signature["Woods::GraphAnalyzer#normalize_cycle_signature"]
  Woods__GraphAnalyzer_generate_sample_pairs["Woods::GraphAnalyzer#generate_sample_pairs"]
  Woods__GraphAnalyzer_generate_sample_pairs -->|method_call| Set
  Woods__GraphAnalyzer_bfs_shortest_path["Woods::GraphAnalyzer#bfs_shortest_path"]
  Woods__GraphAnalyzer_bfs_shortest_path -->|method_call| Set
  Woods__IndexArtifact["Woods::IndexArtifact"]
  Woods__IndexArtifact_initialize["Woods::IndexArtifact#initialize"]
  Woods__IndexArtifact_initialize -->|method_call| Pathname
  Woods__IndexArtifact_output_dir["Woods::IndexArtifact#output_dir"]
  Woods__IndexArtifact_config_path["Woods::IndexArtifact#config_path"]
  Woods__IndexArtifact_dumps_root["Woods::IndexArtifact#dumps_root"]
  Woods__IndexArtifact_latest_pointer_path["Woods::IndexArtifact#latest_pointer_path"]
  Woods__IndexArtifact_fresh_["Woods::IndexArtifact#fresh?"]
  Woods__IndexArtifact_latest_dump_path["Woods::IndexArtifact#latest_dump_path"]
  Woods__IndexArtifact_dump_config_path["Woods::IndexArtifact#dump_config_path"]
  Woods__IndexArtifact_dump_config_path -->|method_call| Pathname_new
  Woods__IndexArtifact_dump_config_path -->|method_call| Pathname
  Woods__IndexArtifact_read_config["Woods::IndexArtifact#read_config"]
  Woods__IndexArtifact_read_config -->|method_call| JSON
  Woods__IndexArtifact_new_dump_dir["Woods::IndexArtifact#new_dump_dir"]
  Woods__IndexArtifact_new_dump_dir -->|method_call| FileUtils
  Woods__IndexArtifact_new_dump_dir -->|method_call| Dir
  Woods__IndexArtifact_promote["Woods::IndexArtifact#promote"]
  Woods__IndexArtifact_promote -->|method_call| Pathname
  Woods__IndexArtifact_promote -->|method_call| Pathname_new
  Pathname_new_realpath["Pathname.new.realpath"]
  Woods__IndexArtifact_promote -->|method_call| Pathname_new_realpath
  Woods__IndexArtifact_write_config["Woods::IndexArtifact#write_config"]
  Woods__IndexArtifact_write_dump_config["Woods::IndexArtifact#write_dump_config"]
  Woods__IndexArtifact_serialize_config["Woods::IndexArtifact#serialize_config"]
  Woods__IndexArtifact_serialize_config -->|method_call| JSON
  Woods__IndexArtifact_atomic_write["Woods::IndexArtifact#atomic_write"]
  Woods__IndexArtifact_atomic_write -->|method_call| FileUtils
  Woods__IndexArtifact_atomic_write -->|method_call| Tempfile
  Woods__IndexArtifact_atomic_write -->|method_call| File
  Woods__MCP["Woods::MCP"]
  Woods__MCP__BearerAuth["Woods::MCP::BearerAuth"]
  Woods__MCP__BearerAuth_initialize["Woods::MCP::BearerAuth#initialize"]
  Woods__MCP__BearerAuth_call["Woods::MCP::BearerAuth#call"]
  Rack__Utils["Rack::Utils"]
  Woods__MCP__BearerAuth_call -->|method_call| Rack__Utils
  Woods__MCP__BearerAuth_guard_["Woods::MCP::BearerAuth#guard?"]
  Woods__MCP__BearerAuth_resolve_token["Woods::MCP::BearerAuth#resolve_token"]
  Woods__MCP__BearerAuth_validate_static_token_["Woods::MCP::BearerAuth#validate_static_token!"]
  Woods__MCP__BearerAuth_warn_unusable_token["Woods::MCP::BearerAuth#warn_unusable_token"]
  Woods__MCP__BearerAuth_unauthorized["Woods::MCP::BearerAuth#unauthorized"]
  Woods__MCP__BootstrapState["Woods::MCP::BootstrapState"]
  Woods__MCP__BootstrapState_initialize["Woods::MCP::BootstrapState#initialize"]
  Woods__MCP__BootstrapState_mark["Woods::MCP::BootstrapState#mark"]
  VALID_STATUSES["VALID_STATUSES"]
  Woods__MCP__BootstrapState_mark -->|method_call| VALID_STATUSES
  Woods__MCP__BootstrapState_to_h["Woods::MCP::BootstrapState#to_h"]
  Woods__MCP__Bootstrapper["Woods::MCP::Bootstrapper"]
  Woods__MCP__Bootstrapper_resolve_index_dir["Woods::MCP::Bootstrapper.resolve_index_dir"]
  Woods__MCP__Bootstrapper_resolve_index_dir -->|method_call| ENV
  Woods__MCP__Bootstrapper_resolve_index_dir -->|method_call| Dir
  Woods__MCP__Bootstrapper_manifest_present_["Woods::MCP::Bootstrapper.manifest_present?"]
  Woods__MCP__Bootstrapper_manifest_present_ -->|method_call| File
  Woods__MCP__Bootstrapper_manifest_present_ -->|method_call| Woods__Generation
  Woods__MCP__Bootstrapper_build_snapshot_store["Woods::MCP::Bootstrapper.build_snapshot_store"]
  Woods__MCP__Bootstrapper_build_snapshot_store -->|method_call| File
  ENV___["ENV.[]"]
  Woods__MCP__Bootstrapper_build_snapshot_store -->|method_call| ENV___
  Woods__MCP__Bootstrapper_build_snapshot_store -->|method_call| ENV
  Woods__MCP__Bootstrapper_build_snapshot_store -->|method_call| Woods_configuration
  Woods__MCP__Bootstrapper_build_snapshot_store -->|method_call| Woods
  Woods__MCP__Bootstrapper_build_snapshot_store -->|method_call| SQLite3__Database
  Woods__Db__Migrator_new["Woods::Db::Migrator.new"]
  Woods__MCP__Bootstrapper_build_snapshot_store -->|method_call| Woods__Db__Migrator_new
  Woods__MCP__Bootstrapper_build_snapshot_store -->|method_call| Woods__Db__Migrator
  Woods__Temporal__SnapshotStore["Woods::Temporal::SnapshotStore"]
  Woods__MCP__Bootstrapper_build_snapshot_store -->|method_call| Woods__Temporal__SnapshotStore
  Woods__Temporal__JsonSnapshotStore["Woods::Temporal::JsonSnapshotStore"]
  Woods__MCP__Bootstrapper_build_snapshot_store -->|method_call| Woods__Temporal__JsonSnapshotStore
  Woods__MCP__Bootstrapper_build_retriever["Woods::MCP::Bootstrapper.build_retriever"]
  BootstrapState["BootstrapState"]
  Woods__MCP__Bootstrapper_build_retriever -->|method_call| BootstrapState
  ConfigResolver["ConfigResolver"]
  Woods__MCP__Bootstrapper_build_retriever -->|method_call| ConfigResolver
  Woods__MCP__Bootstrapper_reload_stores_["Woods::MCP::Bootstrapper.reload_stores!"]
  Woods__MCP__Bootstrapper_reload_stores_ -->|method_call| ConfigResolver
  Woods__MCP__Bootstrapper_populate_reloaded_vector_metadata["Woods::MCP::Bootstrapper.populate_reloaded_vector_metadata"]
  Woods__MCP__Bootstrapper_invalidate_ranker_pagerank_["Woods::MCP::Bootstrapper.invalidate_ranker_pagerank!"]
  Woods__MCP__Bootstrapper_extract_ranker["Woods::MCP::Bootstrapper.extract_ranker"]
  Woods__MCP__Bootstrapper_refill_in_memory_vector_store["Woods::MCP::Bootstrapper.refill_in_memory_vector_store"]
  Woods__MCP__Bootstrapper_refill_in_memory_metadata_store["Woods::MCP::Bootstrapper.refill_in_memory_metadata_store"]
  Woods__MCP__Bootstrapper_refill_in_memory_graph_store["Woods::MCP::Bootstrapper.refill_in_memory_graph_store"]
  Woods__MCP__Bootstrapper_ollama_reachable_["Woods::MCP::Bootstrapper.ollama_reachable?"]
  Woods__MCP__Bootstrapper_ollama_reachable_ -->|method_call| ConfigResolver
  Woods__MCP__Bootstrapper_build_resolved_config["Woods::MCP::Bootstrapper.build_resolved_config"]
  Woods__Builder_new["Woods::Builder.new"]
  Woods__MCP__Bootstrapper_build_resolved_config -->|method_call| Woods__Builder_new
  Woods__MCP__Bootstrapper_build_resolved_config -->|method_call| Woods__Builder
  ResolvedConfig["ResolvedConfig"]
  Woods__MCP__Bootstrapper_build_resolved_config -->|method_call| ResolvedConfig
  Woods__MCP__Bootstrapper_build_artifact["Woods::MCP::Bootstrapper.build_artifact"]
  Woods__MCP__Bootstrapper_build_artifact -->|method_call| Woods_configuration
  Woods__MCP__Bootstrapper_build_artifact -->|method_call| Woods
  Woods__MCP__Bootstrapper_build_artifact -->|method_call| IndexArtifact
  Woods__MCP__Bootstrapper_build_retriever_from_config["Woods::MCP::Bootstrapper.build_retriever_from_config"]
  Woods__MCP__Bootstrapper_build_retriever_from_config -->|method_call| Woods__Builder_new
  Woods__MCP__Bootstrapper_build_retriever_from_config -->|method_call| Woods__Builder
  Woods__MCP__Bootstrapper_hydrated_graph_store["Woods::MCP::Bootstrapper.hydrated_graph_store"]
  Woods__MCP__Bootstrapper_hydrated_graph_store -->|method_call| Woods__Generation
  Woods__MCP__Bootstrapper_hydrated_graph_store -->|method_call| Woods__Builder_new
  Woods__MCP__Bootstrapper_hydrated_graph_store -->|method_call| Woods__Builder
  Woods__MCP__Bootstrapper_hydrated_graph_store -->|method_call| Woods__DependencyGraph
  Woods__Storage__GraphStore__Memory["Woods::Storage::GraphStore::Memory"]
  Woods__MCP__Bootstrapper_hydrated_graph_store -->|method_call| Woods__Storage__GraphStore__Memory
  Woods__MCP__Bootstrapper_populate_vector_metadata["Woods::MCP::Bootstrapper.populate_vector_metadata"]
  Woods__MCP__Bootstrapper_implements_own_["Woods::MCP::Bootstrapper.implements_own?"]
  Woods__MCP__Bootstrapper_vector_filter_metadata["Woods::MCP::Bootstrapper.vector_filter_metadata"]
  Woods__MCP__Bootstrapper_hydrated_vector_store["Woods::MCP::Bootstrapper.hydrated_vector_store"]
  Woods__Storage__Snapshotter__Vector["Woods::Storage::Snapshotter::Vector"]
  Woods__MCP__Bootstrapper_hydrated_vector_store -->|method_call| Woods__Storage__Snapshotter__Vector
  Woods__MCP__Bootstrapper_hydrated_metadata_store["Woods::MCP::Bootstrapper.hydrated_metadata_store"]
  Woods__Storage__Snapshotter__Metadata["Woods::Storage::Snapshotter::Metadata"]
  Woods__MCP__Bootstrapper_hydrated_metadata_store -->|method_call| Woods__Storage__Snapshotter__Metadata
  Woods__MCP__Bootstrapper_probe_and_mark_state["Woods::MCP::Bootstrapper.probe_and_mark_state"]
  Woods__MCP__Bootstrapper_probe_and_mark_state -->|method_call| Woods__Builder_new
  Woods__MCP__Bootstrapper_probe_and_mark_state -->|method_call| Woods__Builder
  ProviderProbe["ProviderProbe"]
  Woods__MCP__Bootstrapper_probe_and_mark_state -->|method_call| ProviderProbe
  Woods__MCP__ConfigResolver["Woods::MCP::ConfigResolver"]
  Woods__MCP__ConfigResolver_resolve["Woods::MCP::ConfigResolver.resolve"]
  Woods__MCP__ConfigResolver_read_stored_config["Woods::MCP::ConfigResolver.read_stored_config"]
  Woods__MCP__ConfigResolver_read_stored_config -->|method_call| ResolvedConfig
  Woods__MCP__ConfigResolver_apply_stored_config["Woods::MCP::ConfigResolver.apply_stored_config"]
  Woods__MCP__ConfigResolver_live_resolved_config["Woods::MCP::ConfigResolver.live_resolved_config"]
  Woods__MCP__ConfigResolver_live_resolved_config -->|method_call| Woods__Builder_new
  Woods__MCP__ConfigResolver_live_resolved_config -->|method_call| Woods__Builder
  Woods__MCP__ConfigResolver_live_resolved_config -->|method_call| ResolvedConfig
  Woods__MCP__ConfigResolver_populate_from_stored["Woods::MCP::ConfigResolver.populate_from_stored"]
  Woods__MCP__ConfigResolver_restore_store_options["Woods::MCP::ConfigResolver.restore_store_options"]
  Woods__MCP__ConfigResolver_require_store_setting_["Woods::MCP::ConfigResolver.require_store_setting!"]
  Woods__MCP__ConfigResolver_provider_symbol["Woods::MCP::ConfigResolver.provider_symbol"]
  Woods__MCP__ConfigResolver_resolve_without_artifact["Woods::MCP::ConfigResolver.resolve_without_artifact"]
  Woods__MCP__ConfigResolver_autodetect_from_env["Woods::MCP::ConfigResolver.autodetect_from_env"]
  Woods__MCP__ConfigResolver_ollama_reachable_["Woods::MCP::ConfigResolver.ollama_reachable?"]
  Woods__MCP__ConfigResolver_ollama_reachable_ -->|method_call| ENV
  URI["URI"]
  Woods__MCP__ConfigResolver_ollama_reachable_ -->|method_call| URI
  Woods__MCP__ConfigResolver_ollama_reachable_ -->|method_call| Net__HTTP
  Woods__MCP__BootstrapError["Woods::MCP::BootstrapError"]
  Woods__MCP__BootstrapError -->|inheritance| Woods__Error
  Woods__MCP__MissingCredential["Woods::MCP::MissingCredential"]
  BootstrapError["BootstrapError"]
  Woods__MCP__MissingCredential -->|inheritance| BootstrapError
  Woods__MCP__ConfigMismatch["Woods::MCP::ConfigMismatch"]
  Woods__MCP__ConfigMismatch -->|inheritance| BootstrapError
  Woods__MCP__DimensionMismatch["Woods::MCP::DimensionMismatch"]
  Woods__MCP__DimensionMismatch -->|inheritance| BootstrapError
  Woods__MCP__UnsupportedArtifact["Woods::MCP::UnsupportedArtifact"]
  Woods__MCP__UnsupportedArtifact -->|inheritance| BootstrapError
  Woods__MCP__MissingArtifact["Woods::MCP::MissingArtifact"]
  Woods__MCP__MissingArtifact -->|inheritance| BootstrapError
  Woods__MCP__ProviderUnreachable["Woods::MCP::ProviderUnreachable"]
  Woods__MCP__ProviderUnreachable -->|inheritance| Woods__Error
  Woods__MCP__BootstrapError_initialize["Woods::MCP::BootstrapError#initialize"]
  Woods__MCP__ProviderUnreachable_initialize["Woods::MCP::ProviderUnreachable#initialize"]
  Woods__MCP__ProviderUnreachable_default_message["Woods::MCP::ProviderUnreachable#default_message"]
  Woods__MCP__IndexReader["Woods::MCP::IndexReader"]
  Woods__MCP__IndexReader_initialize["Woods::MCP::IndexReader#initialize"]
  Woods__MCP__IndexReader_initialize -->|method_call| Pathname
  Woods__MCP__IndexReader_initialize -->|method_call| Hash
  Woods__MCP__IndexReader_initialize -->|method_call| Mutex
  Woods__MCP__IndexReader_initialize -->|method_call| ConditionVariable
  Woods__MCP__IndexReader_initialize -->|method_call| Woods__Generation
  Woods__MCP__IndexReader_ensure_fresh_["Woods::MCP::IndexReader#ensure_fresh!"]
  Woods__MCP__IndexReader_ensure_fresh_ -->|method_call| Thread
  Woods__MCP__IndexReader_with_pinned_generation["Woods::MCP::IndexReader#with_pinned_generation"]
  Woods__MCP__IndexReader_with_pinned_generation -->|method_call| Thread
  Woods__MCP__IndexReader_with_exclusive_reload["Woods::MCP::IndexReader#with_exclusive_reload"]
  Woods__MCP__IndexReader_with_exclusive_reload -->|method_call| Thread
  Woods__MCP__IndexReader_warmup_["Woods::MCP::IndexReader#warmup!"]
  Woods__MCP__IndexReader_reload_["Woods::MCP::IndexReader#reload!"]
  Woods__MCP__IndexReader_payload_dir["Woods::MCP::IndexReader#payload_dir"]
  Woods__MCP__IndexReader_manifest["Woods::MCP::IndexReader#manifest"]
  Woods__MCP__IndexReader_template_engines["Woods::MCP::IndexReader#template_engines"]
  Woods__MCP__IndexReader_template_engines -->|method_call| Woods__Extractors__ViewTemplateExtractor_supported_template_engines
  Woods__MCP__IndexReader_template_engines -->|method_call| Woods__Extractors__ViewTemplateExtractor
  Woods__MCP__IndexReader_summary["Woods::MCP::IndexReader#summary"]
  Woods__MCP__IndexReader_dependency_graph["Woods::MCP::IndexReader#dependency_graph"]
  Woods__MCP__IndexReader_dependency_graph -->|method_call| Woods__DependencyGraph
  Woods__MCP__IndexReader_graph_analysis["Woods::MCP::IndexReader#graph_analysis"]
  Woods__MCP__IndexReader_find_unit["Woods::MCP::IndexReader#find_unit"]
  Woods__MCP__IndexReader_list_units["Woods::MCP::IndexReader#list_units"]
  TYPE_TO_DIR["TYPE_TO_DIR"]
  Woods__MCP__IndexReader_list_units -->|method_call| TYPE_TO_DIR
  Woods__MCP__IndexReader_search["Woods::MCP::IndexReader#search"]
  Woods__MCP__IndexReader_search_within_pin["Woods::MCP::IndexReader#search_within_pin"]
  ENV_fetch_to_s["ENV.fetch.to_s"]
  Woods__MCP__IndexReader_search_within_pin -->|method_call| ENV_fetch_to_s
  Woods__MCP__IndexReader_search_within_pin -->|method_call| ENV_fetch
  Woods__MCP__IndexReader_search_within_pin -->|method_call| ENV
  Woods__MCP__IndexReader_search_within_pin -->|method_call| TYPE_TO_DIR
  DIR_TO_TYPE["DIR_TO_TYPE"]
  Woods__MCP__IndexReader_search_within_pin -->|method_call| DIR_TO_TYPE
  Woods__MCP__IndexReader_traverse_dependencies["Woods::MCP::IndexReader#traverse_dependencies"]
  Woods__MCP__IndexReader_traverse_dependents["Woods::MCP::IndexReader#traverse_dependents"]
  Woods__MCP__IndexReader_framework_sources["Woods::MCP::IndexReader#framework_sources"]
  Woods__MCP__IndexReader_framework_sources_within_pin["Woods::MCP::IndexReader#framework_sources_within_pin"]
  Woods__MCP__IndexReader_framework_sources_within_pin -->|method_call| Regexp
  Woods__MCP__IndexReader_recent_changes["Woods::MCP::IndexReader#recent_changes"]
  Woods__MCP__IndexReader_recent_changes_within_pin["Woods::MCP::IndexReader#recent_changes_within_pin"]
  Woods__MCP__IndexReader_recent_changes_within_pin -->|method_call| TYPE_TO_DIR
  Woods__MCP__IndexReader_raw_graph_data["Woods::MCP::IndexReader#raw_graph_data"]
  Woods__MCP__IndexReader_wait_for_generation_access["Woods::MCP::IndexReader#wait_for_generation_access"]
  Woods__MCP__IndexReader_generation_access_blocked_["Woods::MCP::IndexReader#generation_access_blocked?"]
  Woods__MCP__IndexReader_release_generation_pin["Woods::MCP::IndexReader#release_generation_pin"]
  Woods__MCP__IndexReader_acquire_exclusive_generation["Woods::MCP::IndexReader#acquire_exclusive_generation"]
  Woods__MCP__IndexReader_release_exclusive_generation["Woods::MCP::IndexReader#release_exclusive_generation"]
  Woods__MCP__IndexReader_refresh_if_stale["Woods::MCP::IndexReader#refresh_if_stale"]
  Woods__MCP__IndexReader_manifest_present_["Woods::MCP::IndexReader#manifest_present?"]
  Woods__MCP__IndexReader_manifest_present_ -->|method_call| Woods__Generation_new
  Woods__MCP__IndexReader_manifest_present_ -->|method_call| Woods__Generation
  Woods__MCP__IndexReader_current_payload_dir["Woods::MCP::IndexReader#current_payload_dir"]
  Woods__MCP__IndexReader_resolve_payload_dir["Woods::MCP::IndexReader#resolve_payload_dir"]
  Woods__MCP__IndexReader_resolve_payload_dir -->|method_call| Woods__Generation_new
  Woods__MCP__IndexReader_resolve_payload_dir -->|method_call| Woods__Generation
  Woods__MCP__IndexReader_same_generation_["Woods::MCP::IndexReader#same_generation?"]
  Woods__MCP__IndexReader_warmup_steps["Woods::MCP::IndexReader#warmup_steps"]
  Woods__MCP__IndexReader_compile_search_pattern["Woods::MCP::IndexReader#compile_search_pattern"]
  Woods__MCP__IndexReader_compile_search_pattern -->|method_call| Regexp
  Woods__MCP__IndexReader_generation_signature["Woods::MCP::IndexReader#generation_signature"]
  Woods__MCP__IndexReader_generation_signature -->|method_call| File
  Woods__MCP__IndexReader_identifier_passes_prefix_suffix_["Woods::MCP::IndexReader#identifier_passes_prefix_suffix?"]
  Woods__MCP__IndexReader_identifier_passes_filters_["Woods::MCP::IndexReader#identifier_passes_filters?"]
  Woods__MCP__IndexReader_normalized_graph_edges["Woods::MCP::IndexReader#normalized_graph_edges"]
  Woods__MCP__IndexReader_graph_node_types["Woods::MCP::IndexReader#graph_node_types"]
  Woods__MCP__IndexReader_variant_records["Woods::MCP::IndexReader#variant_records"]
  Woods__MCP__IndexReader_identifier_map["Woods::MCP::IndexReader#identifier_map"]
  Woods__MCP__IndexReader_build_identifier_map["Woods::MCP::IndexReader#build_identifier_map"]
  TYPE_DIRS["TYPE_DIRS"]
  Woods__MCP__IndexReader_build_identifier_map -->|method_call| TYPE_DIRS
  Woods__MCP__IndexReader_build_identifier_map -->|method_call| Digest__SHA256_hexdigest
  Woods__MCP__IndexReader_build_identifier_map -->|method_call| Digest__SHA256
  Woods__MCP__IndexReader_read_index["Woods::MCP::IndexReader#read_index"]
  Woods__MCP__IndexReader_read_index -->|method_call| JSON
  Woods__MCP__IndexReader_load_unit["Woods::MCP::IndexReader#load_unit"]
  Woods__MCP__IndexReader_load_unit -->|method_call| JSON
  Woods__MCP__IndexReader_unit_file_signature["Woods::MCP::IndexReader#unit_file_signature"]
  Woods__MCP__IndexReader_open_unit["Woods::MCP::IndexReader#open_unit"]
  Woods__MCP__IndexReader_open_unit -->|method_call| File
  Woods__MCP__IndexReader_parse_json["Woods::MCP::IndexReader#parse_json"]
  Woods__MCP__IndexReader_parse_json -->|method_call| JSON
  Woods__MCP__IndexReader_traverse["Woods::MCP::IndexReader#traverse"]
  Woods__MCP__IndexReader_traverse -->|method_call| Set
  Woods__MCP__IndexReader_normalize_all_edges["Woods::MCP::IndexReader#normalize_all_edges"]
  Woods__MCP__IndexReader_resolve_forward_neighbors["Woods::MCP::IndexReader#resolve_forward_neighbors"]
  Woods__MCP__IndexReader_resolve_reverse_neighbors["Woods::MCP::IndexReader#resolve_reverse_neighbors"]
  Woods__MCP__IndexReaderPinning["Woods::MCP::IndexReaderPinning"]
  Woods__MCP__IndexReaderPinning__Dispatch["Woods::MCP::IndexReaderPinning::Dispatch"]
  Woods__MCP__IndexReaderPinning__Dispatch_call_tool["Woods::MCP::IndexReaderPinning::Dispatch#call_tool"]
  Woods__MCP__IndexReaderPinning__Dispatch_read_resource_contents["Woods::MCP::IndexReaderPinning::Dispatch#read_resource_contents"]
  Woods__MCP__OriginGuard["Woods::MCP::OriginGuard"]
  Woods__MCP__OriginGuard_initialize["Woods::MCP::OriginGuard#initialize"]
  Woods__MCP__OriginGuard_call["Woods::MCP::OriginGuard#call"]
  Woods__MCP__OriginGuard_guard_["Woods::MCP::OriginGuard#guard?"]
  Woods__MCP__OriginGuard_build_allow_list["Woods::MCP::OriginGuard#build_allow_list"]
  Array_compact_reject["Array.compact.reject"]
  Woods__MCP__OriginGuard_build_allow_list -->|method_call| Array_compact_reject
  DEFAULT_ALLOWED["DEFAULT_ALLOWED"]
  Woods__MCP__OriginGuard_build_allow_list -->|method_call| DEFAULT_ALLOWED
  Woods__MCP__OriginGuard_allowed["Woods::MCP::OriginGuard#allowed"]
  Woods__MCP__OriginGuard_allowed_hosts["Woods::MCP::OriginGuard#allowed_hosts"]
  Woods__MCP__OriginGuard_normalize["Woods::MCP::OriginGuard#normalize"]
  Woods__MCP__OriginGuard_extract_host["Woods::MCP::OriginGuard#extract_host"]
  Woods__MCP__OriginGuard_host_allowed_["Woods::MCP::OriginGuard#host_allowed?"]
  Util__HostGuard["Util::HostGuard"]
  Woods__MCP__OriginGuard_host_allowed_ -->|method_call| Util__HostGuard
  LOOPBACK_HOSTS["LOOPBACK_HOSTS"]
  Woods__MCP__OriginGuard_host_allowed_ -->|method_call| LOOPBACK_HOSTS
  Woods__MCP__OriginGuard_origin_allowed_["Woods::MCP::OriginGuard#origin_allowed?"]
  Woods__MCP__OriginGuard_preflight["Woods::MCP::OriginGuard#preflight"]
  Woods__MCP__OriginGuard_cors_headers["Woods::MCP::OriginGuard#cors_headers"]
  Woods__MCP__OriginGuard_forbidden["Woods::MCP::OriginGuard#forbidden"]
  Woods__MCP__OriginGuard_forbidden_host["Woods::MCP::OriginGuard#forbidden_host"]
  Woods__MCP__ProtocolPolicy["Woods::MCP::ProtocolPolicy"]
  Woods__MCP__ProviderProbe["Woods::MCP::ProviderProbe"]
  Woods__MCP__ProviderProbe_reachable_["Woods::MCP::ProviderProbe.reachable!"]
  Woods__MCP__ProviderProbe_provider_object_["Woods::MCP::ProviderProbe.provider_object?"]
  Woods__MCP__ProviderProbe_probe_ollama_["Woods::MCP::ProviderProbe.probe_ollama!"]
  Woods__MCP__ProviderProbe_probe_openai_["Woods::MCP::ProviderProbe.probe_openai!"]
  Woods__MCP__ProviderProbe_openai_unreachable_reason["Woods::MCP::ProviderProbe.openai_unreachable_reason"]
  Woods__MCP__ProviderProbe_http_get_["Woods::MCP::ProviderProbe.http_get!"]
  Woods__MCP__ProviderProbe_http_get_ -->|method_call| URI
  Woods__MCP__ProviderProbe_http_get_ -->|method_call| Net__HTTP
  Woods__MCP__Renderers["Woods::MCP::Renderers"]
  Woods__MCP__Renderers__ClaudeRenderer["Woods::MCP::Renderers::ClaudeRenderer"]
  MarkdownRenderer["MarkdownRenderer"]
  Woods__MCP__Renderers__ClaudeRenderer -->|inheritance| MarkdownRenderer
  Woods__MCP__Renderers__ClaudeRenderer_render_lookup["Woods::MCP::Renderers::ClaudeRenderer#render_lookup"]
  Woods__MCP__Renderers__ClaudeRenderer_render_search["Woods::MCP::Renderers::ClaudeRenderer#render_search"]
  Woods__MCP__Renderers__ClaudeRenderer_render_dependencies["Woods::MCP::Renderers::ClaudeRenderer#render_dependencies"]
  Woods__MCP__Renderers__ClaudeRenderer_render_dependents["Woods::MCP::Renderers::ClaudeRenderer#render_dependents"]
  Woods__MCP__Renderers__ClaudeRenderer_render_structure["Woods::MCP::Renderers::ClaudeRenderer#render_structure"]
  Woods__MCP__Renderers__ClaudeRenderer_render_graph_analysis["Woods::MCP::Renderers::ClaudeRenderer#render_graph_analysis"]
  Woods__MCP__Renderers__ClaudeRenderer_render_pagerank["Woods::MCP::Renderers::ClaudeRenderer#render_pagerank"]
  Woods__MCP__Renderers__ClaudeRenderer_render_framework["Woods::MCP::Renderers::ClaudeRenderer#render_framework"]
  Woods__MCP__Renderers__ClaudeRenderer_render_recent_changes["Woods::MCP::Renderers::ClaudeRenderer#render_recent_changes"]
  Woods__MCP__Renderers__ClaudeRenderer_render_trace_flow["Woods::MCP::Renderers::ClaudeRenderer#render_trace_flow"]
  Woods__MCP__Renderers__ClaudeRenderer_render_default["Woods::MCP::Renderers::ClaudeRenderer#render_default"]
  Woods__MCP__Renderers__ClaudeRenderer_wrap_xml["Woods::MCP::Renderers::ClaudeRenderer#wrap_xml"]
  Woods__MCP__Renderers__JsonRenderer["Woods::MCP::Renderers::JsonRenderer"]
  ToolResponseRenderer["ToolResponseRenderer"]
  Woods__MCP__Renderers__JsonRenderer -->|inheritance| ToolResponseRenderer
  Woods__MCP__Renderers__JsonRenderer_render_default["Woods::MCP::Renderers::JsonRenderer#render_default"]
  Woods__MCP__Renderers__JsonRenderer_render_default -->|method_call| JSON
  Woods__MCP__Renderers__MarkdownRenderer["Woods::MCP::Renderers::MarkdownRenderer"]
  Woods__MCP__Renderers__MarkdownRenderer -->|inheritance| ToolResponseRenderer
  Woods__MCP__Renderers__MarkdownRenderer_render_lookup["Woods::MCP::Renderers::MarkdownRenderer#render_lookup"]
  Woods__MCP__Renderers__MarkdownRenderer_render_search["Woods::MCP::Renderers::MarkdownRenderer#render_search"]
  Woods__MCP__Renderers__MarkdownRenderer_render_dependencies["Woods::MCP::Renderers::MarkdownRenderer#render_dependencies"]
  Woods__MCP__Renderers__MarkdownRenderer_render_dependents["Woods::MCP::Renderers::MarkdownRenderer#render_dependents"]
  Woods__MCP__Renderers__MarkdownRenderer_render_structure["Woods::MCP::Renderers::MarkdownRenderer#render_structure"]
  Woods__MCP__Renderers__MarkdownRenderer_structure_denominators_glossary["Woods::MCP::Renderers::MarkdownRenderer#structure_denominators_glossary"]
  Woods__MCP__Renderers__MarkdownRenderer_render_graph_analysis["Woods::MCP::Renderers::MarkdownRenderer#render_graph_analysis"]
  Woods__MCP__Renderers__MarkdownRenderer_render_domain_clusters["Woods::MCP::Renderers::MarkdownRenderer#render_domain_clusters"]
  Woods__MCP__Renderers__MarkdownRenderer_render_pagerank["Woods::MCP::Renderers::MarkdownRenderer#render_pagerank"]
  Woods__MCP__Renderers__MarkdownRenderer_render_framework["Woods::MCP::Renderers::MarkdownRenderer#render_framework"]
  Woods__MCP__Renderers__MarkdownRenderer_render_recent_changes["Woods::MCP::Renderers::MarkdownRenderer#render_recent_changes"]
  Woods__MCP__Renderers__MarkdownRenderer_render_trace_flow["Woods::MCP::Renderers::MarkdownRenderer#render_trace_flow"]
  Woods__MCP__Renderers__MarkdownRenderer_render_trace_flow -->|method_call| Woods__FlowDocument_from_h
  Woods__MCP__Renderers__MarkdownRenderer_render_trace_flow -->|method_call| Woods__FlowDocument
  Woods__MCP__Renderers__MarkdownRenderer_render_default["Woods::MCP::Renderers::MarkdownRenderer#render_default"]
  Woods__MCP__Renderers__MarkdownRenderer_render_traversal["Woods::MCP::Renderers::MarkdownRenderer#render_traversal"]
  Woods__MCP__Renderers__MarkdownRenderer_render_metadata_section["Woods::MCP::Renderers::MarkdownRenderer#render_metadata_section"]
  Woods__MCP__Renderers__MarkdownRenderer_render_hash_as_markdown["Woods::MCP::Renderers::MarkdownRenderer#render_hash_as_markdown"]
  Woods__MCP__Renderers__MarkdownRenderer_render_array_as_markdown["Woods::MCP::Renderers::MarkdownRenderer#render_array_as_markdown"]
  Woods__MCP__Renderers__PlainRenderer["Woods::MCP::Renderers::PlainRenderer"]
  Woods__MCP__Renderers__PlainRenderer -->|inheritance| ToolResponseRenderer
  Woods__MCP__Renderers__PlainRenderer_render_lookup["Woods::MCP::Renderers::PlainRenderer#render_lookup"]
  Woods__MCP__Renderers__PlainRenderer_render_search["Woods::MCP::Renderers::PlainRenderer#render_search"]
  Woods__MCP__Renderers__PlainRenderer_render_dependencies["Woods::MCP::Renderers::PlainRenderer#render_dependencies"]
  Woods__MCP__Renderers__PlainRenderer_render_dependents["Woods::MCP::Renderers::PlainRenderer#render_dependents"]
  Woods__MCP__Renderers__PlainRenderer_render_structure["Woods::MCP::Renderers::PlainRenderer#render_structure"]
  Woods__MCP__Renderers__PlainRenderer_render_graph_analysis["Woods::MCP::Renderers::PlainRenderer#render_graph_analysis"]
  Woods__MCP__Renderers__PlainRenderer_render_pagerank["Woods::MCP::Renderers::PlainRenderer#render_pagerank"]
  Woods__MCP__Renderers__PlainRenderer_render_framework["Woods::MCP::Renderers::PlainRenderer#render_framework"]
  Woods__MCP__Renderers__PlainRenderer_render_recent_changes["Woods::MCP::Renderers::PlainRenderer#render_recent_changes"]
  Woods__MCP__Renderers__PlainRenderer_render_default["Woods::MCP::Renderers::PlainRenderer#render_default"]
  Woods__MCP__Renderers__PlainRenderer_render_plain_traversal["Woods::MCP::Renderers::PlainRenderer#render_plain_traversal"]
  Woods__MCP__Server["Woods::MCP::Server"]
  Woods__MCP__Tasks["Woods::MCP::Tasks"]
  Woods__MCP__Tasks__Extension["Woods::MCP::Tasks::Extension"]
  Woods__MCP__Tasks__RequestCapture["Woods::MCP::Tasks::RequestCapture"]
  Woods__MCP__Tasks__RequestCapture_tasks_requested_["Woods::MCP::Tasks::RequestCapture.tasks_requested?"]
  Thread_current___["Thread.current.[]"]
  Woods__MCP__Tasks__RequestCapture_tasks_requested_ -->|method_call| Thread_current___
  Woods__MCP__Tasks__RequestCapture_tasks_requested_ -->|method_call| Thread_current
  Woods__MCP__Tasks__RequestCapture_tasks_requested_ -->|method_call| Thread
  Woods__MCP__Tasks__RequestCapture_call_tool["Woods::MCP::Tasks::RequestCapture#call_tool"]
  Woods__MCP__Tasks__RequestCapture_call_tool -->|method_call| Thread_current
  Woods__MCP__Tasks__RequestCapture_call_tool -->|method_call| Thread
  Woods__MCP__Tasks__Store["Woods::MCP::Tasks::Store"]
  Woods__MCP__Tasks__Store__CorruptRecordError["Woods::MCP::Tasks::Store::CorruptRecordError"]
  Woods__MCP__Tasks__Store__CorruptRecordError -->|inheritance| StandardError
  Woods__MCP__Tasks__Store__ProducerIdentityError["Woods::MCP::Tasks::Store::ProducerIdentityError"]
  IOError["IOError"]
  Woods__MCP__Tasks__Store__ProducerIdentityError -->|inheritance| IOError
  Woods__MCP__Tasks__Store_initialize["Woods::MCP::Tasks::Store#initialize"]
  Woods__MCP__Tasks__Store_initialize -->|method_call| File
  Woods__MCP__Tasks__Store_create_["Woods::MCP::Tasks::Store#create!"]
  Time_now_utc["Time.now.utc"]
  Woods__MCP__Tasks__Store_create_ -->|method_call| Time_now_utc
  Woods__MCP__Tasks__Store_create_ -->|method_call| Time_now
  Woods__MCP__Tasks__Store_create_ -->|method_call| Time
  Task["Task"]
  Woods__MCP__Tasks__Store_create_ -->|method_call| Task
  Woods__MCP__Tasks__Store_get["Woods::MCP::Tasks::Store#get"]
  Woods__MCP__Tasks__Store_complete_["Woods::MCP::Tasks::Store#complete!"]
  Woods__MCP__Tasks__Store_fail_["Woods::MCP::Tasks::Store#fail!"]
  Woods__MCP__Tasks__Store_path_for["Woods::MCP::Tasks::Store#path_for"]
  Woods__MCP__Tasks__Store_path_for -->|method_call| File
  Woods__MCP__Tasks__Store_read["Woods::MCP::Tasks::Store#read"]
  Woods__MCP__Tasks__Store_read -->|method_call| File
  Woods__MCP__Tasks__Store_read -->|method_call| JSON
  Woods__MCP__Tasks__Store_read -->|method_call| Task
  Woods__MCP__Tasks__Store_write["Woods::MCP::Tasks::Store#write"]
  Woods__MCP__Tasks__Store_write -->|method_call| FileUtils
  Woods__MCP__Tasks__Store_write -->|method_call| Woods__AtomicFile
  Woods__MCP__Tasks__Store_valid_record_["Woods::MCP::Tasks::Store#valid_record?"]
  STATUSES["STATUSES"]
  Woods__MCP__Tasks__Store_valid_record_ -->|method_call| STATUSES
  Woods__MCP__Tasks__Store_valid_status_fields_["Woods::MCP::Tasks::Store#valid_status_fields?"]
  Woods__MCP__Tasks__Store_valid_producer_["Woods::MCP::Tasks::Store#valid_producer?"]
  Woods__MCP__Tasks__Store_valid_error_["Woods::MCP::Tasks::Store#valid_error?"]
  Woods__MCP__Tasks__Store_valid_input_requests_["Woods::MCP::Tasks::Store#valid_input_requests?"]
  Woods__MCP__Tasks__Store_absent_["Woods::MCP::Tasks::Store#absent?"]
  Woods__MCP__Tasks__Store_valid_time_["Woods::MCP::Tasks::Store#valid_time?"]
  Woods__MCP__Tasks__Store_valid_time_ -->|method_call| Time
  Woods__MCP__Tasks__Store_transition_["Woods::MCP::Tasks::Store#transition!"]
  Woods__MCP__Tasks__Store_with_task_lock["Woods::MCP::Tasks::Store#with_task_lock"]
  Woods__MCP__Tasks__Store_with_task_lock -->|method_call| FileUtils
  Woods__MCP__Tasks__Store_with_task_lock -->|method_call| File
  Woods__MCP__Tasks__Store_expired_["Woods::MCP::Tasks::Store#expired?"]
  Time_now_utc__["Time.now.utc.-"]
  Woods__MCP__Tasks__Store_expired_ -->|method_call| Time_now_utc__
  Woods__MCP__Tasks__Store_expired_ -->|method_call| Time_now_utc
  Woods__MCP__Tasks__Store_expired_ -->|method_call| Time_now
  Woods__MCP__Tasks__Store_expired_ -->|method_call| Time
  Woods__MCP__Tasks__Store_adopt_orphan["Woods::MCP::Tasks::Store#adopt_orphan"]
  Woods__MCP__Tasks__Store_producer_alive_["Woods::MCP::Tasks::Store#producer_alive?"]
  Woods__MCP__Tasks__Store_foreign_boot_["Woods::MCP::Tasks::Store#foreign_boot?"]
  Woods__MCP__Tasks__Store_current_boot_identity["Woods::MCP::Tasks::Store#current_boot_identity"]
  Woods__MCP__Tasks__Store_current_boot_identity -->|method_call| File
  File_read["File.read"]
  Woods__MCP__Tasks__Store_current_boot_identity -->|method_call| File_read
  Woods__MCP__Tasks__Store_process_alive_["Woods::MCP::Tasks::Store#process_alive?"]
  Woods__MCP__Tasks__Store_process_alive_ -->|method_call| Process
  Woods__MCP__Tasks__Store_producer_identity_for["Woods::MCP::Tasks::Store#producer_identity_for"]
  Woods__MCP__Tasks__Store_producer_identity_for -->|method_call| File
  Woods__MCP__Tasks__Store_linux_process_identity["Woods::MCP::Tasks::Store#linux_process_identity"]
  Woods__MCP__Tasks__Store_linux_process_identity -->|method_call| File_read
  Woods__MCP__Tasks__Store_linux_process_identity -->|method_call| File
  Woods__MCP__Tasks__Store_linux_start_ticks["Woods::MCP::Tasks::Store#linux_start_ticks"]
  Woods__MCP__Tasks__Store_darwin_process_identity["Woods::MCP::Tasks::Store#darwin_process_identity"]
  Woods__MCP__Tasks__Store_darwin_process_identity -->|method_call| Open3
  DateTime_strptime_to_time["DateTime.strptime.to_time"]
  Woods__MCP__Tasks__Store_darwin_process_identity -->|method_call| DateTime_strptime_to_time
  DateTime_strptime["DateTime.strptime"]
  Woods__MCP__Tasks__Store_darwin_process_identity -->|method_call| DateTime_strptime
  DateTime["DateTime"]
  Woods__MCP__Tasks__Store_darwin_process_identity -->|method_call| DateTime
  Woods__MCP__Tasks__Store_darwin_boot_identity["Woods::MCP::Tasks::Store#darwin_boot_identity"]
  Woods__MCP__Tasks__Store_darwin_boot_identity -->|method_call| Open3
  Woods__MCP__Tasks__Store_sweep_expired_["Woods::MCP::Tasks::Store#sweep_expired!"]
  Woods__MCP__Tasks__Store_sweep_expired_ -->|method_call| Dir
  Woods__MCP__Tasks__Store_sweep_expired_ -->|method_call| Dir_glob
  Woods__MCP__Tasks__Store_sweep_expired_ -->|method_call| File
  Woods__MCP__Tasks__Store_sweep_expired_ -->|method_call| FileUtils
  Woods__MCP__Tasks__Store_corrupt_record_expired_["Woods::MCP::Tasks::Store#corrupt_record_expired?"]
  Woods__MCP__Tasks__Store_corrupt_record_expired_ -->|method_call| Time_now_utc__
  Woods__MCP__Tasks__Store_corrupt_record_expired_ -->|method_call| Time_now_utc
  Woods__MCP__Tasks__Store_corrupt_record_expired_ -->|method_call| Time_now
  Woods__MCP__Tasks__Store_corrupt_record_expired_ -->|method_call| Time
  Woods__MCP__ToolContract["Woods::MCP::ToolContract"]
  Woods__MCP__ToolContract__Dispatch["Woods::MCP::ToolContract::Dispatch"]
  Woods__MCP__ToolContract__Dispatch_call_tool["Woods::MCP::ToolContract::Dispatch#call_tool"]
  ToolContract["ToolContract"]
  Woods__MCP__ToolContract__Dispatch_call_tool -->|method_call| ToolContract
  Woods__MCP__ToolContract__Dispatch_contract_error["Woods::MCP::ToolContract::Dispatch#contract_error"]
  MCP__Tool__Response_new["MCP::Tool::Response.new"]
  Woods__MCP__ToolContract__Dispatch_contract_error -->|method_call| MCP__Tool__Response_new
  Woods__MCP__ToolContract__Dispatch_contract_error -->|method_call| MCP__Tool__Response
  Woods__MCP__ToolResponseRenderer["Woods::MCP::ToolResponseRenderer"]
  Woods__MCP__ToolResponseRenderer_for["Woods::MCP::ToolResponseRenderer.for"]
  Renderers__ClaudeRenderer["Renderers::ClaudeRenderer"]
  Woods__MCP__ToolResponseRenderer_for -->|method_call| Renderers__ClaudeRenderer
  Renderers__MarkdownRenderer["Renderers::MarkdownRenderer"]
  Woods__MCP__ToolResponseRenderer_for -->|method_call| Renderers__MarkdownRenderer
  Renderers__PlainRenderer["Renderers::PlainRenderer"]
  Woods__MCP__ToolResponseRenderer_for -->|method_call| Renderers__PlainRenderer
  Renderers__JsonRenderer["Renderers::JsonRenderer"]
  Woods__MCP__ToolResponseRenderer_for -->|method_call| Renderers__JsonRenderer
  Woods__MCP__ToolResponseRenderer_render["Woods::MCP::ToolResponseRenderer#render"]
  Woods__MCP__ToolResponseRenderer_render_default["Woods::MCP::ToolResponseRenderer#render_default"]
  Woods__MCP__ToolResponseRenderer_fetch_key["Woods::MCP::ToolResponseRenderer#fetch_key"]
  Woods__MCP__VersionAwareToolDispatch["Woods::MCP::VersionAwareToolDispatch"]
  Woods__MCP__VersionAwareToolDispatch_call_tool["Woods::MCP::VersionAwareToolDispatch#call_tool"]
  Woods__MCP__VersionAwareToolDispatch_tool_not_found_error_["Woods::MCP::VersionAwareToolDispatch#tool_not_found_error?"]
  Woods__ModelNameCache["Woods::ModelNameCache"]
  Woods__Notion["Woods::Notion"]
  Woods__Notion__AuthenticationError["Woods::Notion::AuthenticationError"]
  Woods__Notion__AuthenticationError -->|inheritance| Woods__Error
  Woods__Notion__Client["Woods::Notion::Client"]
  Woods__Notion__Client_initialize["Woods::Notion::Client#initialize"]
  Woods__Notion__Client_create_page["Woods::Notion::Client#create_page"]
  Woods__Notion__Client_update_page["Woods::Notion::Client#update_page"]
  Woods__Notion__Client_query_database["Woods::Notion::Client#query_database"]
  Woods__Notion__Client_find_page_by_title["Woods::Notion::Client#find_page_by_title"]
  Woods__Notion__Client_request["Woods::Notion::Client#request"]
  Woods__Notion__Client_request -->|method_call| JSON
  RETRYABLE_STATUS_CODES["RETRYABLE_STATUS_CODES"]
  Woods__Notion__Client_request -->|method_call| RETRYABLE_STATUS_CODES
  Woods__RetryAfter["Woods::RetryAfter"]
  Woods__Notion__Client_request -->|method_call| Woods__RetryAfter
  Woods__Notion__Client_execute_with_retry["Woods::Notion::Client#execute_with_retry"]
  Woods__Notion__Client_safe_to_retry_["Woods::Notion::Client#safe_to_retry?"]
  IDEMPOTENT_METHODS["IDEMPOTENT_METHODS"]
  Woods__Notion__Client_safe_to_retry_ -->|method_call| IDEMPOTENT_METHODS
  PRE_REQUEST_ERRORS["PRE_REQUEST_ERRORS"]
  Woods__Notion__Client_safe_to_retry_ -->|method_call| PRE_REQUEST_ERRORS
  Woods__Notion__Client_raise_ambiguous_network_error["Woods::Notion::Client#raise_ambiguous_network_error"]
  Woods__Notion__Client_raise_ambiguous_response_error["Woods::Notion::Client#raise_ambiguous_response_error"]
  Woods__Notion__Client_raise_ambiguous_response_error -->|method_call| JSON
  Woods__Notion__Client_raise_api_error["Woods::Notion::Client#raise_api_error"]
  Woods__Notion__Client_raise_api_error -->|method_call| JSON
  AUTH_STATUS_CODES["AUTH_STATUS_CODES"]
  Woods__Notion__Client_raise_api_error -->|method_call| AUTH_STATUS_CODES
  Woods__Notion__Client_redact_token["Woods::Notion::Client#redact_token"]
  Woods__Notion__Client_execute_http["Woods::Notion::Client#execute_http"]
  Woods__Notion__Client_execute_http -->|method_call| Net__HTTP
  Woods__Notion__Client_build_request["Woods::Notion::Client#build_request"]
  Woods__Notion__Client_build_request -->|method_call| Net__HTTP__Post
  Net__HTTP__Patch["Net::HTTP::Patch"]
  Woods__Notion__Client_build_request -->|method_call| Net__HTTP__Patch
  Net__HTTP__Get["Net::HTTP::Get"]
  Woods__Notion__Client_build_request -->|method_call| Net__HTTP__Get
  Woods__Notion__Exporter["Woods::Notion::Exporter"]
  Woods__Notion__Exporter_initialize["Woods::Notion::Exporter#initialize"]
  Woods__Notion__Exporter_initialize -->|method_call| Woods
  Client["Client"]
  Woods__Notion__Exporter_initialize -->|method_call| Client
  Woods__Notion__Exporter_sync_all["Woods::Notion::Exporter#sync_all"]
  Woods__Notion__Exporter_sync_data_models["Woods::Notion::Exporter#sync_data_models"]
  Mappers__ModelMapper_new["Mappers::ModelMapper.new"]
  Woods__Notion__Exporter_sync_data_models -->|method_call| Mappers__ModelMapper_new
  Mappers__ModelMapper["Mappers::ModelMapper"]
  Woods__Notion__Exporter_sync_data_models -->|method_call| Mappers__ModelMapper
  Woods__Notion__Exporter_sync_columns["Woods::Notion::Exporter#sync_columns"]
  Woods__Notion__Exporter_sync_units["Woods::Notion::Exporter#sync_units"]
  Woods__Notion__Exporter_each_model_unit["Woods::Notion::Exporter#each_model_unit"]
  Woods__Notion__Exporter_sync_model_columns["Woods::Notion::Exporter#sync_model_columns"]
  Woods__Notion__Exporter_sync_model_columns -->|method_call| Mappers__ModelMapper
  Mappers__ColumnMapper["Mappers::ColumnMapper"]
  Woods__Notion__Exporter_sync_model_columns -->|method_call| Mappers__ColumnMapper
  Woods__Notion__Exporter_sync_page["Woods::Notion::Exporter#sync_page"]
  SyncManifest["SyncManifest"]
  Woods__Notion__Exporter_sync_page -->|method_call| SyncManifest
  Woods__Notion__Exporter_update_cached_page["Woods::Notion::Exporter#update_cached_page"]
  Woods__Notion__Exporter_column_legacy_descriptor["Woods::Notion::Exporter#column_legacy_descriptor"]
  Woods__Notion__Exporter_enrich_with_migration_date["Woods::Notion::Exporter#enrich_with_migration_date"]
  Woods__Notion__Exporter_load_migration_dates["Woods::Notion::Exporter#load_migration_dates"]
  Mappers__MigrationMapper["Mappers::MigrationMapper"]
  Woods__Notion__Exporter_load_migration_dates -->|method_call| Mappers__MigrationMapper
  Woods__Notion__Exporter_upsert_page["Woods::Notion::Exporter#upsert_page"]
  Woods__Notion__Exporter_adopt_legacy_page["Woods::Notion::Exporter#adopt_legacy_page"]
  Woods__Notion__Exporter_warn_ambiguous_legacy["Woods::Notion::Exporter#warn_ambiguous_legacy"]
  Woods__Notion__Exporter_query_legacy_pages["Woods::Notion::Exporter#query_legacy_pages"]
  Woods__Notion__Exporter_shared_table_names["Woods::Notion::Exporter#shared_table_names"]
  Woods__Notion__Exporter_shared_table_names -->|method_call| Hash
  Woods__Notion__Exporter_shared_table_names -->|method_call| Mappers__ModelMapper
  Woods__Notion__Exporter_qualify_shared_table_title["Woods::Notion::Exporter#qualify_shared_table_title"]
  Woods__Notion__Exporter_qualify_shared_table_title -->|method_call| Mappers__ModelMapper
  Woods__Notion__Exporter_save_manifest["Woods::Notion::Exporter#save_manifest"]
  Woods__Notion__Exporter_build_manifest["Woods::Notion::Exporter#build_manifest"]
  Woods__Notion__Exporter_build_manifest -->|method_call| SyncManifest
  Woods__Notion__Exporter_env_force_["Woods::Notion::Exporter#env_force?"]
  Woods__Notion__Exporter_empty_stats["Woods::Notion::Exporter#empty_stats"]
  Woods__Notion__Exporter_cap_errors["Woods::Notion::Exporter#cap_errors"]
  Woods__Notion__Exporter_extract_title_text["Woods::Notion::Exporter#extract_title_text"]
  Woods__Notion__Exporter_build_reader["Woods::Notion::Exporter#build_reader"]
  Woods__Notion__Exporter_build_reader -->|method_call| Woods__MCP__IndexReader
  Woods__Notion__Mappers["Woods::Notion::Mappers"]
  Woods__Notion__Mappers__ColumnMapper["Woods::Notion::Mappers::ColumnMapper"]
  Shared["Shared"]
  Woods__Notion__Mappers__ColumnMapper -->|include| Shared
  Woods__Notion__Mappers__ColumnMapper_map["Woods::Notion::Mappers::ColumnMapper#map"]
  Woods__Notion__Mappers__ColumnMapper_qualified_title["Woods::Notion::Mappers::ColumnMapper#qualified_title"]
  Woods__Notion__Mappers__ColumnMapper_format_validation_rules["Woods::Notion::Mappers::ColumnMapper#format_validation_rules"]
  Woods__Notion__Mappers__MigrationMapper["Woods::Notion::Mappers::MigrationMapper"]
  Woods__Notion__Mappers__MigrationMapper_latest_changes["Woods::Notion::Mappers::MigrationMapper#latest_changes"]
  Woods__Notion__Mappers__MigrationMapper_update_latest["Woods::Notion::Mappers::MigrationMapper#update_latest"]
  Woods__Notion__Mappers__ModelMapper["Woods::Notion::Mappers::ModelMapper"]
  Woods__Notion__Mappers__ModelMapper -->|include| Shared
  Woods__Notion__Mappers__ModelMapper_table_name_for["Woods::Notion::Mappers::ModelMapper.table_name_for"]
  Woods__Notion__Mappers__ModelMapper_map["Woods::Notion::Mappers::ModelMapper#map"]
  Woods__Notion__Mappers__ModelMapper_build_text_properties["Woods::Notion::Mappers::ModelMapper#build_text_properties"]
  Woods__Notion__Mappers__ModelMapper_add_git_properties["Woods::Notion::Mappers::ModelMapper#add_git_properties"]
  Woods__Notion__Mappers__ModelMapper_table_name["Woods::Notion::Mappers::ModelMapper#table_name"]
  Woods__Notion__Mappers__ModelMapper_column_count["Woods::Notion::Mappers::ModelMapper#column_count"]
  Woods__Notion__Mappers__ModelMapper_extract_description["Woods::Notion::Mappers::ModelMapper#extract_description"]
  Woods__Notion__Mappers__ModelMapper_redact_credentials["Woods::Notion::Mappers::ModelMapper#redact_credentials"]
  Woods__Notion__Mappers__ModelMapper_scanner["Woods::Notion::Mappers::ModelMapper#scanner"]
  Woods__Notion__Mappers__ModelMapper_scanner -->|method_call| Woods__Console__CredentialScanner
  Woods__Notion__Mappers__ModelMapper_format_associations["Woods::Notion::Mappers::ModelMapper#format_associations"]
  Woods__Notion__Mappers__ModelMapper_format_single_association["Woods::Notion::Mappers::ModelMapper#format_single_association"]
  Woods__Notion__Mappers__ModelMapper_format_validations["Woods::Notion::Mappers::ModelMapper#format_validations"]
  Woods__Notion__Mappers__ModelMapper_format_callbacks["Woods::Notion::Mappers::ModelMapper#format_callbacks"]
  Woods__Notion__Mappers__ModelMapper_format_single_callback["Woods::Notion::Mappers::ModelMapper#format_single_callback"]
  Woods__Notion__Mappers__ModelMapper_callback_side_effects["Woods::Notion::Mappers::ModelMapper#callback_side_effects"]
  Woods__Notion__Mappers__ModelMapper_format_scopes["Woods::Notion::Mappers::ModelMapper#format_scopes"]
  Woods__Notion__Mappers__ModelMapper_format_dependencies["Woods::Notion::Mappers::ModelMapper#format_dependencies"]
  Woods__Notion__Mappers__ModelMapper_title_property["Woods::Notion::Mappers::ModelMapper#title_property"]
  Woods__Notion__Mappers__ModelMapper_format_list["Woods::Notion::Mappers::ModelMapper#format_list"]
  Woods__Notion__Mappers__Shared["Woods::Notion::Mappers::Shared"]
  Woods__Notion__Mappers__Shared_rich_text_property["Woods::Notion::Mappers::Shared#rich_text_property"]
  Woods__Notion__RateLimiter["Woods::Notion::RateLimiter"]
  Woods__Notion__RateLimiter_initialize["Woods::Notion::RateLimiter#initialize"]
  Woods__Notion__RateLimiter_initialize -->|method_call| Mutex
  Woods__Notion__RateLimiter_throttle["Woods::Notion::RateLimiter#throttle"]
  Woods__Notion__RateLimiter_wait_for_interval["Woods::Notion::RateLimiter#wait_for_interval"]
  Woods__Notion__RateLimiter_monotonic_now["Woods::Notion::RateLimiter#monotonic_now"]
  Woods__Notion__RateLimiter_monotonic_now -->|method_call| Process
  Woods__Notion__SyncManifest["Woods::Notion::SyncManifest"]
  Woods__Notion__SyncManifest_content_hash["Woods::Notion::SyncManifest.content_hash"]
  Woods__Notion__SyncManifest_content_hash -->|method_call| Digest__SHA256
  Woods__Notion__SyncManifest_canonicalize["Woods::Notion::SyncManifest.canonicalize"]
  Woods__Notion__SyncManifest_initialize["Woods::Notion::SyncManifest#initialize"]
  Woods__Notion__SyncManifest_empty_["Woods::Notion::SyncManifest#empty?"]
  Woods__Notion__SyncManifest_size["Woods::Notion::SyncManifest#size"]
  Woods__Notion__SyncManifest_unchanged_["Woods::Notion::SyncManifest#unchanged?"]
  Woods__Notion__SyncManifest_page_id_for["Woods::Notion::SyncManifest#page_id_for"]
  Woods__Notion__SyncManifest_record["Woods::Notion::SyncManifest#record"]
  Woods__Notion__SyncManifest_forget["Woods::Notion::SyncManifest#forget"]
  Woods__Notion__SyncManifest_prune["Woods::Notion::SyncManifest#prune"]
  Woods__Notion__SyncManifest_save["Woods::Notion::SyncManifest#save"]
  Woods__Notion__SyncManifest_save -->|method_call| JSON
  Woods__Notion__SyncManifest_save -->|method_call| AtomicFile
  Woods__Notion__SyncManifest_normalize_database_ids["Woods::Notion::SyncManifest#normalize_database_ids"]
  Woods__Notion__SyncManifest_load["Woods::Notion::SyncManifest#load"]
  Woods__Notion__SyncManifest_load -->|method_call| File
  Woods__Notion__SyncManifest_load -->|method_call| JSON
  Woods__Notion__SyncManifest_select_current_scopes["Woods::Notion::SyncManifest#select_current_scopes"]
  Woods__Notion__SyncManifest_load_scope["Woods::Notion::SyncManifest#load_scope"]
  Woods__Notion__SyncManifest_current_scope_["Woods::Notion::SyncManifest#current_scope?"]
  Woods__Notion__SyncManifest_warn_scope_discard["Woods::Notion::SyncManifest#warn_scope_discard"]
  Woods__Notion__SyncManifest_discard["Woods::Notion::SyncManifest#discard"]
  Woods__Observability["Woods::Observability"]
  Woods__Observability__StructuredLogger_initialize["Woods::Observability::StructuredLogger#initialize"]
  Woods__Observability__StructuredLogger_write_entry["Woods::Observability::StructuredLogger#write_entry"]
  Woods__Obsidian["Woods::Obsidian"]
  Woods__Obsidian__ExportError["Woods::Obsidian::ExportError"]
  Woods__Obsidian__ExportError -->|inheritance| Woods__Error
  Woods__Obsidian__PathTraversalError["Woods::Obsidian::PathTraversalError"]
  ExportError["ExportError"]
  Woods__Obsidian__PathTraversalError -->|inheritance| ExportError
  Woods__Obsidian__NameMapper["Woods::Obsidian::NameMapper"]
  Woods__Obsidian__NameMapper_initialize["Woods::Obsidian::NameMapper#initialize"]
  Woods__Obsidian__NameMapper_path_for["Woods::Obsidian::NameMapper#path_for"]
  Woods__Obsidian__NameMapper_wikilink["Woods::Obsidian::NameMapper#wikilink"]
  Woods__Obsidian__NameMapper_paths_to_ids["Woods::Obsidian::NameMapper#paths_to_ids"]
  Woods__Obsidian__NameMapper_build["Woods::Obsidian::NameMapper#build"]
  Woods__Obsidian__NameMapper_build -->|method_call| Hash
  Woods__Obsidian__NameMapper_assign_basename["Woods::Obsidian::NameMapper#assign_basename"]
  Woods__Obsidian__NameMapper_sanitize["Woods::Obsidian::NameMapper#sanitize"]
  Woods__Obsidian__NameMapper_alias_for["Woods::Obsidian::NameMapper#alias_for"]
  Woods__Obsidian__NameMapper_fit["Woods::Obsidian::NameMapper#fit"]
  MAX_FILENAME_BYTES["MAX_FILENAME_BYTES"]
  Woods__Obsidian__NameMapper_fit -->|method_call| MAX_FILENAME_BYTES
  Woods__Obsidian__NoteBuilder["Woods::Obsidian::NoteBuilder"]
  Woods__Obsidian__NoteBuilder_initialize["Woods::Obsidian::NoteBuilder#initialize"]
  Woods__Obsidian__NoteBuilder_build["Woods::Obsidian::NoteBuilder#build"]
  Woods__Obsidian__NoteBuilder_frontmatter["Woods::Obsidian::NoteBuilder#frontmatter"]
  Woods__Obsidian__NoteBuilder_pagerank_for["Woods::Obsidian::NoteBuilder#pagerank_for"]
  Woods__Obsidian__NoteBuilder_tags_for["Woods::Obsidian::NoteBuilder#tags_for"]
  Woods__Obsidian__NoteBuilder_heading["Woods::Obsidian::NoteBuilder#heading"]
  Woods__Obsidian__NoteBuilder_meta_line["Woods::Obsidian::NoteBuilder#meta_line"]
  Woods__Obsidian__NoteBuilder_table_part["Woods::Obsidian::NoteBuilder#table_part"]
  Woods__Obsidian__NoteBuilder_callout["Woods::Obsidian::NoteBuilder#callout"]
  Woods__Obsidian__NoteBuilder_depends_section["Woods::Obsidian::NoteBuilder#depends_section"]
  Woods__Obsidian__NoteBuilder_used_by_section["Woods::Obsidian::NoteBuilder#used_by_section"]
  Woods__Obsidian__NoteBuilder_associations_section["Woods::Obsidian::NoteBuilder#associations_section"]
  Woods__Export__UnitFacts_new["Woods::Export::UnitFacts.new"]
  Woods__Obsidian__NoteBuilder_associations_section -->|method_call| Woods__Export__UnitFacts_new
  Woods__Obsidian__NoteBuilder_associations_section -->|method_call| Woods__Export__UnitFacts
  ASSOCIATION_ORDER["ASSOCIATION_ORDER"]
  Woods__Obsidian__NoteBuilder_associations_section -->|method_call| ASSOCIATION_ORDER
  Woods__Obsidian__NoteBuilder_render_associations["Woods::Obsidian::NoteBuilder#render_associations"]
  Woods__Obsidian__NoteBuilder_schema_section["Woods::Obsidian::NoteBuilder#schema_section"]
  Woods__Obsidian__NoteBuilder_schema_section -->|method_call| Woods__Export__UnitFacts_new
  Woods__Obsidian__NoteBuilder_schema_section -->|method_call| Woods__Export__UnitFacts
  Woods__Obsidian__NoteBuilder_format_callbacks["Woods::Obsidian::NoteBuilder#format_callbacks"]
  Woods__Obsidian__NoteBuilder_source_section["Woods::Obsidian::NoteBuilder#source_section"]
  Woods__Obsidian__NoteBuilder_scrub["Woods::Obsidian::NoteBuilder#scrub"]
  Woods__Obsidian__NoteBuilder_identifier_set["Woods::Obsidian::NoteBuilder#identifier_set"]
  Woods__Obsidian__NoteBuilder_identifier_set -->|method_call| Set
  Woods__Obsidian__NoteBuilder_plain_set["Woods::Obsidian::NoteBuilder#plain_set"]
  Woods__Obsidian__NoteBuilder_plain_set -->|method_call| Set
  Woods__Obsidian__NoteBuilder_cycle_member_set["Woods::Obsidian::NoteBuilder#cycle_member_set"]
  Woods__Obsidian__NoteBuilder_cycle_member_set -->|method_call| Set
  Woods__Obsidian__NoteBuilder_pluralize["Woods::Obsidian::NoteBuilder#pluralize"]
  Woods__Obsidian__VaultAssets["Woods::Obsidian::VaultAssets"]
  Woods__Obsidian__VaultAssets_app_json["Woods::Obsidian::VaultAssets#app_json"]
  Woods__Obsidian__VaultAssets_types_json["Woods::Obsidian::VaultAssets#types_json"]
  Woods__Obsidian__VaultAssets_graph_json["Woods::Obsidian::VaultAssets#graph_json"]
  Array_uniq_sort_each_with_index["Array.uniq.sort.each_with_index"]
  Woods__Obsidian__VaultAssets_graph_json -->|method_call| Array_uniq_sort_each_with_index
  Woods__Obsidian__VaultAssets_units_base["Woods::Obsidian::VaultAssets#units_base"]
  Woods__Obsidian__VaultAssets_pretty["Woods::Obsidian::VaultAssets#pretty"]
  Woods__Obsidian__VaultExporter["Woods::Obsidian::VaultExporter"]
  Woods__Obsidian__VaultExporter_initialize["Woods::Obsidian::VaultExporter#initialize"]
  Woods__Obsidian__VaultExporter_initialize -->|method_call| Pathname
  Woods__Obsidian__VaultExporter_export_all["Woods::Obsidian::VaultExporter#export_all"]
  Woods__Obsidian__VaultExporter_export_all -->|method_call| Set
  Woods__Obsidian__VaultExporter_partition_emitted["Woods::Obsidian::VaultExporter#partition_emitted"]
  FRAMEWORK_TYPES["FRAMEWORK_TYPES"]
  Woods__Obsidian__VaultExporter_partition_emitted -->|method_call| FRAMEWORK_TYPES
  Woods__Obsidian__VaultExporter_load_unit["Woods::Obsidian::VaultExporter#load_unit"]
  Woods__Obsidian__VaultExporter_known_ids["Woods::Obsidian::VaultExporter#known_ids"]
  Woods__Obsidian__VaultExporter_build_mapper["Woods::Obsidian::VaultExporter#build_mapper"]
  NameMapper["NameMapper"]
  Woods__Obsidian__VaultExporter_build_mapper -->|method_call| NameMapper
  Woods__Obsidian__VaultExporter_dir_for["Woods::Obsidian::VaultExporter#dir_for"]
  Woods__MCP__IndexReader__TYPE_TO_DIR["Woods::MCP::IndexReader::TYPE_TO_DIR"]
  Woods__Obsidian__VaultExporter_dir_for -->|method_call| Woods__MCP__IndexReader__TYPE_TO_DIR
  Woods__Obsidian__VaultExporter_sanitize_dir_segment["Woods::Obsidian::VaultExporter#sanitize_dir_segment"]
  Woods__Obsidian__VaultExporter_build_note_builder["Woods::Obsidian::VaultExporter#build_note_builder"]
  NoteBuilder["NoteBuilder"]
  Woods__Obsidian__VaultExporter_build_note_builder -->|method_call| NoteBuilder
  Woods__Obsidian__VaultExporter_build_edge_map["Woods::Obsidian::VaultExporter#build_edge_map"]
  Woods__Obsidian__VaultExporter_build_edge_map -->|method_call| Array_filter_map
  Array_select["Array.select"]
  Woods__Obsidian__VaultExporter_build_edge_map -->|method_call| Array_select
  Woods__Obsidian__VaultExporter_build_edge_map -->|method_call| Array
  Woods__Obsidian__VaultExporter_forward_edge["Woods::Obsidian::VaultExporter#forward_edge"]
  Woods__Obsidian__VaultExporter_write_notes["Woods::Obsidian::VaultExporter#write_notes"]
  Woods__Obsidian__VaultExporter_write_indexes["Woods::Obsidian::VaultExporter#write_indexes"]
  Woods__Obsidian__VaultExporter_write_indexes -->|method_call| File
  Woods__Obsidian__VaultExporter_moc_note["Woods::Obsidian::VaultExporter#moc_note"]
  Woods__Obsidian__VaultExporter_overview_note["Woods::Obsidian::VaultExporter#overview_note"]
  Woods__Obsidian__VaultExporter_managed_frontmatter["Woods::Obsidian::VaultExporter#managed_frontmatter"]
  Woods__Obsidian__VaultExporter_write_sidecar["Woods::Obsidian::VaultExporter#write_sidecar"]
  Woods__Obsidian__VaultExporter_write_owned_assets["Woods::Obsidian::VaultExporter#write_owned_assets"]
  Woods__Obsidian__VaultExporter_can_write_obsidian_config_["Woods::Obsidian::VaultExporter#can_write_obsidian_config?"]
  Woods__Obsidian__VaultExporter_present_types["Woods::Obsidian::VaultExporter#present_types"]
  Woods__Obsidian__VaultExporter_sweep["Woods::Obsidian::VaultExporter#sweep"]
  Woods__Obsidian__VaultExporter_sweep -->|method_call| File
  Woods__Obsidian__VaultExporter_managed_notes["Woods::Obsidian::VaultExporter#managed_notes"]
  Woods__Obsidian__VaultExporter_managed_notes -->|method_call| Dir_glob
  Pathname_new_relative_path_from["Pathname.new.relative_path_from"]
  Woods__Obsidian__VaultExporter_managed_notes -->|method_call| Pathname_new_relative_path_from
  Woods__Obsidian__VaultExporter_managed_notes -->|method_call| Pathname_new
  Woods__Obsidian__VaultExporter_managed_notes -->|method_call| Pathname
  Woods__Obsidian__VaultExporter_managed_marker_["Woods::Obsidian::VaultExporter#managed_marker?"]
  Woods__Obsidian__VaultExporter_frontmatter_head["Woods::Obsidian::VaultExporter#frontmatter_head"]
  Woods__Obsidian__VaultExporter_frontmatter_head -->|method_call| File
  MAX_FRONTMATTER_LINES["MAX_FRONTMATTER_LINES"]
  Woods__Obsidian__VaultExporter_frontmatter_head -->|method_call| MAX_FRONTMATTER_LINES
  Woods__Obsidian__VaultExporter_frontmatter_head -->|method_call| YAML
  Woods__Obsidian__VaultExporter_guard_blocks_purge_["Woods::Obsidian::VaultExporter#guard_blocks_purge?"]
  Woods__Obsidian__VaultExporter_safe_inside_vault_["Woods::Obsidian::VaultExporter#safe_inside_vault?"]
  Woods__Obsidian__VaultExporter_canonical["Woods::Obsidian::VaultExporter#canonical"]
  Woods__Obsidian__VaultExporter_canonical -->|method_call| Pathname
  Woods__Obsidian__VaultExporter_canonical -->|method_call| File
  Woods__Obsidian__VaultExporter_safe_write["Woods::Obsidian::VaultExporter#safe_write"]
  Woods__Obsidian__VaultExporter_safe_write -->|method_call| AtomicFile
  Woods__Obsidian__VaultExporter_vault_owned_at_start_["Woods::Obsidian::VaultExporter#vault_owned_at_start?"]
  Woods__Obsidian__VaultExporter_warn_foreign["Woods::Obsidian::VaultExporter#warn_foreign"]
  Woods__Obsidian__VaultExporter_write_managed["Woods::Obsidian::VaultExporter#write_managed"]
  Woods__Obsidian__VaultExporter_write_json["Woods::Obsidian::VaultExporter#write_json"]
  Woods__Obsidian__VaultExporter_sort_hash["Woods::Obsidian::VaultExporter#sort_hash"]
  Woods__Obsidian__VaultExporter_scanner["Woods::Obsidian::VaultExporter#scanner"]
  Woods__Obsidian__VaultExporter_scanner -->|method_call| Woods__Console__CredentialScanner
  Woods__Obsidian__VaultExporter_safe_graph_analysis["Woods::Obsidian::VaultExporter#safe_graph_analysis"]
  Woods__Obsidian__VaultExporter_build_reader["Woods::Obsidian::VaultExporter#build_reader"]
  Woods__Obsidian__VaultExporter_build_reader -->|method_call| Woods__MCP__IndexReader
  Woods__Obsidian__VaultExporter_cap_errors["Woods::Obsidian::VaultExporter#cap_errors"]
  Woods__Obsidian__VaultExporter_log["Woods::Obsidian::VaultExporter#log"]
  Woods__Operator["Woods::Operator"]
  Woods__Operator__ErrorEscalator["Woods::Operator::ErrorEscalator"]
  Woods__Operator__ErrorEscalator_classify["Woods::Operator::ErrorEscalator#classify"]
  Woods__Operator__ErrorEscalator_find_match["Woods::Operator::ErrorEscalator#find_match"]
  Woods__Operator__PipelineGuard["Woods::Operator::PipelineGuard"]
  Woods__Operator__PipelineGuard_initialize["Woods::Operator::PipelineGuard#initialize"]
  Woods__Operator__PipelineGuard_initialize -->|method_call| File
  Woods__Operator__PipelineGuard_allow_["Woods::Operator::PipelineGuard#allow?"]
  Woods__Operator__PipelineGuard_allow_ -->|method_call| Time_now
  Woods__Operator__PipelineGuard_allow_ -->|method_call| Time
  Woods__Operator__PipelineGuard_state_status["Woods::Operator::PipelineGuard#state_status"]
  Woods__Operator__PipelineGuard_state_status -->|method_call| File
  Woods__Operator__PipelineGuard_state_status -->|method_call| JSON
  Woods__Operator__PipelineGuard_record_["Woods::Operator::PipelineGuard#record!"]
  Woods__Operator__PipelineGuard_reset_["Woods::Operator::PipelineGuard#reset!"]
  Woods__Operator__PipelineGuard_last_run["Woods::Operator::PipelineGuard#last_run"]
  Woods__Operator__PipelineGuard_last_run -->|method_call| Time
  Woods__Operator__PipelineGuard_with_locked_state["Woods::Operator::PipelineGuard#with_locked_state"]
  Woods__Operator__PipelineGuard_with_locked_state -->|method_call| FileUtils
  Woods__Operator__PipelineGuard_with_locked_state -->|method_call| File
  Woods__Operator__PipelineGuard_parse_state["Woods::Operator::PipelineGuard#parse_state"]
  Woods__Operator__PipelineGuard_parse_state -->|method_call| JSON
  Woods__Operator__PipelineGuard_requested_state_present_["Woods::Operator::PipelineGuard#requested_state_present?"]
  Woods__Operator__PipelineGuard_requested_state_present_ -->|method_call| File
  Woods__Operator__PipelineGuard_with_existing_locked_state["Woods::Operator::PipelineGuard#with_existing_locked_state"]
  Woods__Operator__PipelineGuard_with_existing_locked_state -->|method_call| File
  Woods__Operator__PipelineGuard_reset_operations["Woods::Operator::PipelineGuard#reset_operations"]
  SUPPORTED_OPERATIONS["SUPPORTED_OPERATIONS"]
  Woods__Operator__PipelineGuard_reset_operations -->|method_call| SUPPORTED_OPERATIONS
  Woods__Operator__PipelineGuard_read_state["Woods::Operator::PipelineGuard#read_state"]
  Woods__Operator__PipelineGuard_read_state -->|method_call| File
  Woods__Operator__StatusReporter["Woods::Operator::StatusReporter"]
  Woods__Operator__StatusReporter_initialize["Woods::Operator::StatusReporter#initialize"]
  Woods__Operator__StatusReporter_report["Woods::Operator::StatusReporter#report"]
  Woods__Operator__StatusReporter_read_manifest["Woods::Operator::StatusReporter#read_manifest"]
  Woods__Operator__StatusReporter_read_manifest -->|method_call| Woods__Generation
  Woods__Operator__StatusReporter_read_manifest -->|method_call| File
  Woods__Operator__StatusReporter_read_manifest -->|method_call| JSON
  Woods__Operator__StatusReporter_not_extracted_report["Woods::Operator::StatusReporter#not_extracted_report"]
  Woods__Operator__StatusReporter_compute_staleness["Woods::Operator::StatusReporter#compute_staleness"]
  Woods__Operator__StatusReporter_compute_staleness -->|method_call| Time_now
  Woods__Operator__StatusReporter_compute_staleness -->|method_call| Time
  Woods__PathDispatcher["Woods::PathDispatcher"]
  Woods__PathDispatcher_file_rules_for["Woods::PathDispatcher#file_rules_for"]
  Woods__PathDispatcher_whole_app_keys_for["Woods::PathDispatcher#whole_app_keys_for"]
  Woods__PathDispatcher_relevant_["Woods::PathDispatcher#relevant?"]
  Woods__PathDispatcher_whole_app_keys_for_all["Woods::PathDispatcher#whole_app_keys_for_all"]
  Woods__PayloadStore["Woods::PayloadStore"]
  Woods__PayloadStore_initialize["Woods::PayloadStore#initialize"]
  Woods__PayloadStore_initialize -->|method_call| Pathname
  Woods__PayloadStore_root["Woods::PayloadStore#root"]
  Woods__PayloadStore_name_for["Woods::PayloadStore.name_for"]
  Woods__PayloadStore_path_for["Woods::PayloadStore#path_for"]
  Woods__PayloadStore_create["Woods::PayloadStore#create"]
  Woods__PayloadStore_create -->|method_call| FileUtils
  Woods__PayloadStore_clone["Woods::PayloadStore#clone"]
  Woods__PayloadStore_clone -->|method_call| Pathname
  Woods__PayloadStore_prune["Woods::PayloadStore#prune"]
  Woods__PayloadStore_link_or_copy["Woods::PayloadStore#link_or_copy"]
  Woods__PayloadStore_link_or_copy -->|method_call| FileUtils
  Woods__PayloadStore_remove_generation_dirs["Woods::PayloadStore#remove_generation_dirs"]
  Woods__PayloadStore_remove_generation_dirs -->|method_call| FileUtils
  Woods__PayloadStore_generation_dirs["Woods::PayloadStore#generation_dirs"]
  Woods__PayloadStore_replicate["Woods::PayloadStore#replicate"]
  Woods__PayloadStore_replicate -->|method_call| FileUtils
  Woods__Railtie["Woods::Railtie"]
  Rails__Railtie["Rails::Railtie"]
  Woods__Railtie -->|inheritance| Rails__Railtie
  Woods__RailtieSupport["Woods::RailtieSupport"]
  Woods__ReleaseV2["Woods::ReleaseV2"]
  Woods__ReleaseV2__SurfaceInventory["Woods::ReleaseV2::SurfaceInventory"]
  Woods__ReleaseV2__SurfaceInventory__DriftError["Woods::ReleaseV2::SurfaceInventory::DriftError"]
  Woods__ReleaseV2__SurfaceInventory__DriftError -->|inheritance| StandardError
  Woods__ReloadPolicy["Woods::ReloadPolicy"]
  Woods__ReloadPolicy_classify["Woods::ReloadPolicy#classify"]
  Woods__ReloadPolicy_classify_all["Woods::ReloadPolicy#classify_all"]
  Woods__ReloadPolicy_classify_all -->|method_call| Array
  Woods__ReloadPolicy_paths_requiring["Woods::ReloadPolicy#paths_requiring"]
  Woods__ReloadPolicy_paths_requiring -->|method_call| Array
  Woods__ReloadPolicy_stronger_of["Woods::ReloadPolicy#stronger_of"]
  ACTIONS_index["ACTIONS.index"]
  Woods__ReloadPolicy_stronger_of -->|method_call| ACTIONS_index
  ACTIONS["ACTIONS"]
  Woods__ReloadPolicy_stronger_of -->|method_call| ACTIONS
  Woods__ReloadPolicy_restart_["Woods::ReloadPolicy#restart?"]
  RESTART_PATHS["RESTART_PATHS"]
  Woods__ReloadPolicy_restart_ -->|method_call| RESTART_PATHS
  RESTART_PATH_PATTERNS["RESTART_PATH_PATTERNS"]
  Woods__ReloadPolicy_restart_ -->|method_call| RESTART_PATH_PATTERNS
  Woods__ReloadPolicy_reload_["Woods::ReloadPolicy#reload?"]
  ROUTE_PATHS["ROUTE_PATHS"]
  Woods__ReloadPolicy_reload_ -->|method_call| ROUTE_PATHS
  Woods__ReloadPolicy_reextract_["Woods::ReloadPolicy#reextract?"]
  REEXTRACT_PATHS["REEXTRACT_PATHS"]
  Woods__ReloadPolicy_reextract_ -->|method_call| REEXTRACT_PATHS
  Woods__ReloadPolicy_under_["Woods::ReloadPolicy#under?"]
  Woods__Resilience["Woods::Resilience"]
  Woods__Resilience__CircuitOpenError["Woods::Resilience::CircuitOpenError"]
  Woods__Resilience__CircuitOpenError -->|inheritance| Woods__Error
  Woods__Resilience__CircuitBreaker["Woods::Resilience::CircuitBreaker"]
  Woods__Resilience__CircuitBreaker_initialize["Woods::Resilience::CircuitBreaker#initialize"]
  Woods__Resilience__CircuitBreaker_initialize -->|method_call| Mutex
  Woods__Resilience__CircuitBreaker_call["Woods::Resilience::CircuitBreaker#call"]
  Woods__Resilience__CircuitBreaker_release_probe["Woods::Resilience::CircuitBreaker#release_probe"]
  Woods__Resilience__CircuitBreaker_finish_failure["Woods::Resilience::CircuitBreaker#finish_failure"]
  Woods__Resilience__CircuitBreaker_finish_success["Woods::Resilience::CircuitBreaker#finish_success"]
  Woods__Resilience__CircuitBreaker_admit_call_["Woods::Resilience::CircuitBreaker#admit_call!"]
  Woods__Resilience__CircuitBreaker_reset_timeout_elapsed_["Woods::Resilience::CircuitBreaker#reset_timeout_elapsed?"]
  Woods__Resilience__CircuitBreaker_monotonic_now["Woods::Resilience::CircuitBreaker#monotonic_now"]
  Woods__Resilience__CircuitBreaker_monotonic_now -->|method_call| Process
  Woods__Resilience__CircuitBreaker_record_failure["Woods::Resilience::CircuitBreaker#record_failure"]
  Woods__Resilience__CircuitBreaker_record_success["Woods::Resilience::CircuitBreaker#record_success"]
  Woods__Resilience__CircuitBreaker_reset_["Woods::Resilience::CircuitBreaker#reset!"]
  Woods__Resilience__IndexValidator["Woods::Resilience::IndexValidator"]
  Woods__Resilience__IndexValidator -->|include| Woods__FilenameUtils
  Woods__Resilience__IndexValidator_initialize["Woods::Resilience::IndexValidator#initialize"]
  Woods__Resilience__IndexValidator_validate["Woods::Resilience::IndexValidator#validate"]
  Woods__Resilience__IndexValidator_validate -->|method_call| Dir
  ValidationReport["ValidationReport"]
  Woods__Resilience__IndexValidator_validate -->|method_call| ValidationReport
  Woods__Resilience__IndexValidator_payload_type_dirs["Woods::Resilience::IndexValidator#payload_type_dirs"]
  Woods__Resilience__IndexValidator_payload_type_dirs -->|method_call| Woods__Generation_new_payload_dir
  Woods__Resilience__IndexValidator_payload_type_dirs -->|method_call| Woods__Generation_new
  Woods__Resilience__IndexValidator_payload_type_dirs -->|method_call| Woods__Generation
  Dir_children["Dir.children"]
  Woods__Resilience__IndexValidator_payload_type_dirs -->|method_call| Dir_children
  Woods__Resilience__IndexValidator_payload_type_dirs -->|method_call| File
  Woods__Resilience__IndexValidator_validate_type_directory["Woods::Resilience::IndexValidator#validate_type_directory"]
  Woods__Resilience__IndexValidator_validate_type_directory -->|method_call| File
  Woods__Resilience__IndexValidator_validate_type_directory -->|method_call| JSON
  Woods__Resilience__IndexValidator_validate_type_directory -->|method_call| Set
  Woods__Resilience__IndexValidator_validate_index_entry["Woods::Resilience::IndexValidator#validate_index_entry"]
  Woods__Resilience__IndexValidator_find_unit_file["Woods::Resilience::IndexValidator#find_unit_file"]
  Woods__Resilience__IndexValidator_find_unit_file -->|method_call| File
  Woods__Resilience__IndexValidator_validate_content_hash["Woods::Resilience::IndexValidator#validate_content_hash"]
  Woods__Resilience__IndexValidator_validate_content_hash -->|method_call| JSON
  Woods__Resilience__IndexValidator_validate_content_hash -->|method_call| Digest__SHA256
  Woods__Resilience__IndexValidator_check_stale_files["Woods::Resilience::IndexValidator#check_stale_files"]
  Woods__Resilience__IndexValidator_check_stale_files -->|method_call| Set
  Woods__Resilience__IndexValidator_check_stale_files -->|method_call| Dir___
  Woods__Resilience__IndexValidator_check_stale_files -->|method_call| File
  Woods__Resilience__RetryableProvider["Woods::Resilience::RetryableProvider"]
  Woods__Resilience__RetryableProvider -->|include| Woods__Embedding__Provider__Interface
  Woods__Resilience__RetryableProvider_initialize["Woods::Resilience::RetryableProvider#initialize"]
  Woods__Resilience__RetryableProvider_embed["Woods::Resilience::RetryableProvider#embed"]
  Woods__Resilience__RetryableProvider_embed_batch["Woods::Resilience::RetryableProvider#embed_batch"]
  Woods__Resilience__RetryableProvider_dimensions["Woods::Resilience::RetryableProvider#dimensions"]
  Woods__Resilience__RetryableProvider_model_name["Woods::Resilience::RetryableProvider#model_name"]
  Woods__Resilience__RetryableProvider_max_input_tokens["Woods::Resilience::RetryableProvider#max_input_tokens"]
  Woods__Resilience__RetryableProvider_with_retries["Woods::Resilience::RetryableProvider#with_retries"]
  Woods__Resilience__RetryableProvider_retryable_error_["Woods::Resilience::RetryableProvider#retryable_error?"]
  Woods__Resilience__RetryableProvider_retry_delay["Woods::Resilience::RetryableProvider#retry_delay"]
  RetryAfter["RetryAfter"]
  Woods__Resilience__RetryableProvider_retry_delay -->|method_call| RetryAfter
  Woods__Resilience__RetryableProvider_backoff_seconds["Woods::Resilience::RetryableProvider#backoff_seconds"]
  BACKOFF_BASE["BACKOFF_BASE"]
  Woods__Resilience__RetryableProvider_backoff_seconds -->|method_call| BACKOFF_BASE
  Woods__Resilience__RetryableProvider_call_provider["Woods::Resilience::RetryableProvider#call_provider"]
  Woods__ResolvedConfig["Woods::ResolvedConfig"]
  Woods__ResolvedConfig_from_hash["Woods::ResolvedConfig.from_hash"]
  Woods__ResolvedConfig_from_configuration["Woods::ResolvedConfig.from_configuration"]
  Woods__ResolvedConfig_initialize["Woods::ResolvedConfig#initialize"]
  Woods__ResolvedConfig_dimension["Woods::ResolvedConfig#dimension"]
  Woods__ResolvedConfig_model_name["Woods::ResolvedConfig#model_name"]
  Woods__ResolvedConfig_provider_signature["Woods::ResolvedConfig#provider_signature"]
  Woods__ResolvedConfig_matches_["Woods::ResolvedConfig#matches?"]
  Woods__ResolvedConfig_assert_compatible_["Woods::ResolvedConfig#assert_compatible!"]
  Woods__ResolvedConfig_to_snapshot_json["Woods::ResolvedConfig#to_snapshot_json"]
  Woods__ResolvedConfig_to_h["Woods::ResolvedConfig#to_h"]
  Woods__ResolvedConfig_stringify_nested_keys["Woods::ResolvedConfig#stringify_nested_keys"]
  Woods__ResolvedConfig_deep_freeze["Woods::ResolvedConfig#deep_freeze"]
  Woods__ResolvedConfig_assert_dimensions_match_["Woods::ResolvedConfig#assert_dimensions_match!"]
  Woods__ResolvedConfig_assert_provider_matches_["Woods::ResolvedConfig#assert_provider_matches!"]
  Woods__Retrieval["Woods::Retrieval"]
  Woods__Retrieval__ContextAssembler["Woods::Retrieval::ContextAssembler"]
  Woods__Retrieval__ContextAssembler_initialize["Woods::Retrieval::ContextAssembler#initialize"]
  Woods__Retrieval__ContextAssembler_assemble["Woods::Retrieval::ContextAssembler#assemble"]
  Woods__Retrieval__ContextAssembler_base_identifier["Woods::Retrieval::ContextAssembler#base_identifier"]
  Woods__Retrieval__ContextAssembler_collapse_chunk_candidates["Woods::Retrieval::ContextAssembler#collapse_chunk_candidates"]
  Woods__Retrieval__ContextAssembler_rewrite_identifier["Woods::Retrieval::ContextAssembler#rewrite_identifier"]
  SearchExecutor__Candidate["SearchExecutor::Candidate"]
  Woods__Retrieval__ContextAssembler_rewrite_identifier -->|method_call| SearchExecutor__Candidate
  Woods__Retrieval__ContextAssembler_add_structural_section["Woods::Retrieval::ContextAssembler#add_structural_section"]
  Woods__Retrieval__ContextAssembler_add_result_sections["Woods::Retrieval::ContextAssembler#add_result_sections"]
  Woods__Retrieval__ContextAssembler_reclaim_empty_supporting_budget["Woods::Retrieval::ContextAssembler#reclaim_empty_supporting_budget"]
  Woods__Retrieval__ContextAssembler_add_candidate_section["Woods::Retrieval::ContextAssembler#add_candidate_section"]
  Woods__Retrieval__ContextAssembler_compute_section_budgets["Woods::Retrieval::ContextAssembler#compute_section_budgets"]
  FRAMEWORK_ACTIVE_ALLOCATION["FRAMEWORK_ACTIVE_ALLOCATION"]
  Woods__Retrieval__ContextAssembler_compute_section_budgets -->|method_call| FRAMEWORK_ACTIVE_ALLOCATION
  FRAMEWORK_INACTIVE_ALLOCATION_transform_values["FRAMEWORK_INACTIVE_ALLOCATION.transform_values"]
  Woods__Retrieval__ContextAssembler_compute_section_budgets -->|method_call| FRAMEWORK_INACTIVE_ALLOCATION_transform_values
  FRAMEWORK_INACTIVE_ALLOCATION["FRAMEWORK_INACTIVE_ALLOCATION"]
  Woods__Retrieval__ContextAssembler_compute_section_budgets -->|method_call| FRAMEWORK_INACTIVE_ALLOCATION
  Woods__Retrieval__ContextAssembler_assemble_section["Woods::Retrieval::ContextAssembler#assemble_section"]
  Woods__Retrieval__ContextAssembler_append_candidate["Woods::Retrieval::ContextAssembler#append_candidate"]
  Woods__Retrieval__ContextAssembler_format_unit["Woods::Retrieval::ContextAssembler#format_unit"]
  Woods__Retrieval__ContextAssembler_build_source_attribution["Woods::Retrieval::ContextAssembler#build_source_attribution"]
  Woods__Retrieval__ContextAssembler_unit_field["Woods::Retrieval::ContextAssembler#unit_field"]
  Woods__Retrieval__ContextAssembler_framework_candidate_["Woods::Retrieval::ContextAssembler#framework_candidate?"]
  Woods__Retrieval__ContextAssembler_type_from_candidate_metadata["Woods::Retrieval::ContextAssembler#type_from_candidate_metadata"]
  Woods__Retrieval__ContextAssembler_type_from_unit_cache["Woods::Retrieval::ContextAssembler#type_from_unit_cache"]
  Woods__Retrieval__ContextAssembler_truncate_to_budget["Woods::Retrieval::ContextAssembler#truncate_to_budget"]
  Woods__Retrieval__ContextAssembler_estimate_tokens["Woods::Retrieval::ContextAssembler#estimate_tokens"]
  Woods__Retrieval__ContextAssembler_effective_chars_per_token["Woods::Retrieval::ContextAssembler#effective_chars_per_token"]
  Woods__Retrieval__ContextAssembler_build_result["Woods::Retrieval::ContextAssembler#build_result"]
  AssembledContext["AssembledContext"]
  Woods__Retrieval__ContextAssembler_build_result -->|method_call| AssembledContext
  Woods__Retrieval__QueryClassifier["Woods::Retrieval::QueryClassifier"]
  Woods__Retrieval__QueryClassifier_classify["Woods::Retrieval::QueryClassifier#classify"]
  Classification["Classification"]
  Woods__Retrieval__QueryClassifier_classify -->|method_call| Classification
  Woods__Retrieval__QueryClassifier_detect_intent["Woods::Retrieval::QueryClassifier#detect_intent"]
  Woods__Retrieval__QueryClassifier_detect_scope["Woods::Retrieval::QueryClassifier#detect_scope"]
  Woods__Retrieval__QueryClassifier_detect_target_type["Woods::Retrieval::QueryClassifier#detect_target_type"]
  Woods__Retrieval__QueryClassifier_match_first["Woods::Retrieval::QueryClassifier#match_first"]
  Woods__Retrieval__QueryClassifier_framework_query_["Woods::Retrieval::QueryClassifier#framework_query?"]
  Woods__Retrieval__QueryClassifier_extract_keywords["Woods::Retrieval::QueryClassifier#extract_keywords"]
  STOP_WORDS["STOP_WORDS"]
  Woods__Retrieval__QueryClassifier_extract_keywords -->|method_call| STOP_WORDS
  Woods__Retrieval__Ranker["Woods::Retrieval::Ranker"]
  Woods__Retrieval__Ranker_initialize["Woods::Retrieval::Ranker#initialize"]
  Woods__Retrieval__Ranker_rank["Woods::Retrieval::Ranker#rank"]
  Woods__Retrieval__Ranker_invalidate_pagerank_cache_["Woods::Retrieval::Ranker#invalidate_pagerank_cache!"]
  Woods__Retrieval__Ranker_finalize_ranked["Woods::Retrieval::Ranker#finalize_ranked"]
  Woods__Retrieval__Ranker_multi_source_["Woods::Retrieval::Ranker#multi_source?"]
  Woods__Retrieval__Ranker_apply_rrf["Woods::Retrieval::Ranker#apply_rrf"]
  Woods__Retrieval__Ranker_compute_rrf_scores["Woods::Retrieval::Ranker#compute_rrf_scores"]
  Woods__Retrieval__Ranker_compute_rrf_scores -->|method_call| Hash
  Woods__Retrieval__Ranker_merge_matched_fields["Woods::Retrieval::Ranker#merge_matched_fields"]
  Woods__Retrieval__Ranker_normalize_scores["Woods::Retrieval::Ranker#normalize_scores"]
  Woods__Retrieval__Ranker_rebuild_rrf_candidates["Woods::Retrieval::Ranker#rebuild_rrf_candidates"]
  Woods__Retrieval__Ranker_pick_merged_source["Woods::Retrieval::Ranker#pick_merged_source"]
  Woods__Retrieval__Ranker_score_candidates["Woods::Retrieval::Ranker#score_candidates"]
  Woods__Retrieval__Ranker_sorted_by_weighted_score["Woods::Retrieval::Ranker#sorted_by_weighted_score"]
  Woods__Retrieval__Ranker_keyword_score["Woods::Retrieval::Ranker#keyword_score"]
  Woods__Retrieval__Ranker_recency_score["Woods::Retrieval::Ranker#recency_score"]
  Woods__Retrieval__Ranker_base_identifier["Woods::Retrieval::Ranker#base_identifier"]
  Woods__Retrieval__Ranker_importance_score["Woods::Retrieval::Ranker#importance_score"]
  Woods__Retrieval__Ranker_pagerank_importance_map["Woods::Retrieval::Ranker#pagerank_importance_map"]
  Woods__Retrieval__Ranker_compute_pagerank_importance_map["Woods::Retrieval::Ranker#compute_pagerank_importance_map"]
  Woods__Retrieval__Ranker_type_match_score["Woods::Retrieval::Ranker#type_match_score"]
  Woods__Retrieval__Ranker_apply_diversity_penalty["Woods::Retrieval::Ranker#apply_diversity_penalty"]
  Woods__Retrieval__Ranker_apply_diversity_penalty -->|method_call| Hash
  Woods__Retrieval__Ranker_diversity_penalty_for["Woods::Retrieval::Ranker#diversity_penalty_for"]
  Woods__Retrieval__Ranker_dig_metadata["Woods::Retrieval::Ranker#dig_metadata"]
  Woods__Retrieval__Ranker_dig_either["Woods::Retrieval::Ranker#dig_either"]
  Woods__Retrieval__Ranker_fetch_either["Woods::Retrieval::Ranker#fetch_either"]
  Woods__Retrieval__Ranker_build_candidate["Woods::Retrieval::Ranker#build_candidate"]
  Woods__Retrieval__Ranker_build_candidate -->|method_call| SearchExecutor__Candidate
  Woods__Retrieval__SearchExecutor["Woods::Retrieval::SearchExecutor"]
  Woods__Retrieval__SearchExecutor_initialize["Woods::Retrieval::SearchExecutor#initialize"]
  Woods__Retrieval__SearchExecutor_execute["Woods::Retrieval::SearchExecutor#execute"]
  ExecutionResult["ExecutionResult"]
  Woods__Retrieval__SearchExecutor_execute -->|method_call| ExecutionResult
  Woods__Retrieval__SearchExecutor_select_strategy["Woods::Retrieval::SearchExecutor#select_strategy"]
  STRATEGY_MAP["STRATEGY_MAP"]
  Woods__Retrieval__SearchExecutor_select_strategy -->|method_call| STRATEGY_MAP
  Woods__Retrieval__SearchExecutor_run_strategy["Woods::Retrieval::SearchExecutor#run_strategy"]
  Woods__Retrieval__SearchExecutor_execute_vector["Woods::Retrieval::SearchExecutor#execute_vector"]
  Candidate["Candidate"]
  Woods__Retrieval__SearchExecutor_execute_vector -->|method_call| Candidate
  Woods__Retrieval__SearchExecutor_execute_keyword["Woods::Retrieval::SearchExecutor#execute_keyword"]
  Woods__Retrieval__SearchExecutor_merge_keyword_results["Woods::Retrieval::SearchExecutor#merge_keyword_results"]
  Woods__Retrieval__SearchExecutor_merge_keyword_hit["Woods::Retrieval::SearchExecutor#merge_keyword_hit"]
  Woods__Retrieval__SearchExecutor_score_keyword_hits["Woods::Retrieval::SearchExecutor#score_keyword_hits"]
  Woods__Retrieval__SearchExecutor_keyword_match_score["Woods::Retrieval::SearchExecutor#keyword_match_score"]
  Woods__Retrieval__SearchExecutor_matched_fields_for["Woods::Retrieval::SearchExecutor#matched_fields_for"]
  KEYWORD_MATCH_SKIPPED_FIELDS["KEYWORD_MATCH_SKIPPED_FIELDS"]
  Woods__Retrieval__SearchExecutor_matched_fields_for -->|method_call| KEYWORD_MATCH_SKIPPED_FIELDS
  Woods__Retrieval__SearchExecutor_rank_keyword_results["Woods::Retrieval::SearchExecutor#rank_keyword_results"]
  Woods__Retrieval__SearchExecutor_rank_keyword_results -->|method_call| Candidate
  Woods__Retrieval__SearchExecutor_execute_graph["Woods::Retrieval::SearchExecutor#execute_graph"]
  Woods__Retrieval__SearchExecutor_execute_hybrid["Woods::Retrieval::SearchExecutor#execute_hybrid"]
  Woods__Retrieval__SearchExecutor_execute_direct["Woods::Retrieval::SearchExecutor#execute_direct"]
  Woods__Retrieval__SearchExecutor_lookup_keyword_variants["Woods::Retrieval::SearchExecutor#lookup_keyword_variants"]
  Woods__Retrieval__SearchExecutor_build_vector_filters["Woods::Retrieval::SearchExecutor#build_vector_filters"]
  Woods__Retrieval__SearchExecutor_find_seed_identifiers["Woods::Retrieval::SearchExecutor#find_seed_identifiers"]
  Woods__Retrieval__SearchExecutor_deduplicate["Woods::Retrieval::SearchExecutor#deduplicate"]
  Woods__Retrieval__SearchExecutor_bounded_candidates["Woods::Retrieval::SearchExecutor#bounded_candidates"]
  Woods__InvalidQueryError["Woods::InvalidQueryError"]
  Woods__InvalidQueryError -->|inheritance| Error
  Woods__Retriever["Woods::Retriever"]
  Woods__Retriever_initialize["Woods::Retriever#initialize"]
  Retrieval__QueryClassifier["Retrieval::QueryClassifier"]
  Woods__Retriever_initialize -->|method_call| Retrieval__QueryClassifier
  Retrieval__SearchExecutor["Retrieval::SearchExecutor"]
  Woods__Retriever_initialize -->|method_call| Retrieval__SearchExecutor
  Retrieval__Ranker["Retrieval::Ranker"]
  Woods__Retriever_initialize -->|method_call| Retrieval__Ranker
  Retrieval__ContextAssembler["Retrieval::ContextAssembler"]
  Woods__Retriever_initialize -->|method_call| Retrieval__ContextAssembler
  Woods__Retriever_infer_chars_per_token["Woods::Retriever#infer_chars_per_token"]
  Woods__Retriever_infer_chars_per_token -->|method_call| TokenUtils
  Woods__Retriever_infer_token_counter["Woods::Retriever#infer_token_counter"]
  Woods__Retriever_infer_token_counter -->|method_call| Embedding__TokenCounter
  Woods__Retriever_retrieve["Woods::Retriever#retrieve"]
  Woods__Retriever_retrieve -->|method_call| Process
  Woods__Retriever_validate_query_["Woods::Retriever#validate_query!"]
  Woods__Retriever_filter_by_type["Woods::Retriever#filter_by_type"]
  Woods__Retriever_filter_by_type -->|method_call| Set
  Woods__Retriever_normalize_type_list["Woods::Retriever#normalize_type_list"]
  Woods__Retriever_candidate_type["Woods::Retriever#candidate_type"]
  Woods__Retriever_type_from_hash["Woods::Retriever#type_from_hash"]
  Woods__Retriever_assemble_context["Woods::Retriever#assemble_context"]
  Woods__Retriever_build_result["Woods::Retriever#build_result"]
  RetrievalResult["RetrievalResult"]
  Woods__Retriever_build_result -->|method_call| RetrievalResult
  Woods__Retriever_apply_type_filter["Woods::Retriever#apply_type_filter"]
  Woods__Retriever_within_type_fallback["Woods::Retriever#within_type_fallback"]
  Woods__Retriever_build_trace["Woods::Retriever#build_trace"]
  Woods__Retriever_build_trace -->|method_call| Process_clock_gettime
  Woods__Retriever_build_trace -->|method_call| Process
  RetrievalTrace["RetrievalTrace"]
  Woods__Retriever_build_trace -->|method_call| RetrievalTrace
  Woods__Retriever_build_type_rank_context["Woods::Retriever#build_type_rank_context"]
  Woods__Retriever_type_source["Woods::Retriever#type_source"]
  Woods__Retriever_total_of_type["Woods::Retriever#total_of_type"]
  Woods__Retriever_append_type_rank_context["Woods::Retriever#append_type_rank_context"]
  Woods__Retriever_build_structural_context["Woods::Retriever#build_structural_context"]
  STRUCTURAL_TYPES["STRUCTURAL_TYPES"]
  Woods__Retriever_build_structural_context -->|method_call| STRUCTURAL_TYPES
  Woods__RetryAfter_seconds["Woods::RetryAfter#seconds"]
  Woods__RetryAfter_raw_seconds["Woods::RetryAfter#raw_seconds"]
  Time_httpdate["Time.httpdate"]
  Woods__RetryAfter_raw_seconds -->|method_call| Time_httpdate
  Woods__RetryAfter_raw_seconds -->|method_call| Time
  Woods__RubyAnalyzer["Woods::RubyAnalyzer"]
  Woods__RubyAnalyzer__ClassAnalyzer["Woods::RubyAnalyzer::ClassAnalyzer"]
  FqnBuilder["FqnBuilder"]
  Woods__RubyAnalyzer__ClassAnalyzer -->|include| FqnBuilder
  Ast__SourceSpan["Ast::SourceSpan"]
  Woods__RubyAnalyzer__ClassAnalyzer -->|include| Ast__SourceSpan
  Woods__RubyAnalyzer__ClassAnalyzer_initialize["Woods::RubyAnalyzer::ClassAnalyzer#initialize"]
  Woods__RubyAnalyzer__ClassAnalyzer_initialize -->|method_call| Ast__Parser
  Woods__RubyAnalyzer__ClassAnalyzer_analyze["Woods::RubyAnalyzer::ClassAnalyzer#analyze"]
  Woods__RubyAnalyzer__ClassAnalyzer_extract_definitions["Woods::RubyAnalyzer::ClassAnalyzer#extract_definitions"]
  Woods__RubyAnalyzer__ClassAnalyzer_process_definition["Woods::RubyAnalyzer::ClassAnalyzer#process_definition"]
  Woods__RubyAnalyzer__ClassAnalyzer_process_definition -->|method_call| ExtractedUnit
  Woods__RubyAnalyzer__ClassAnalyzer_build_namespace["Woods::RubyAnalyzer::ClassAnalyzer#build_namespace"]
  Woods__RubyAnalyzer__ClassAnalyzer_fqn_parts["Woods::RubyAnalyzer::ClassAnalyzer#fqn_parts"]
  Woods__RubyAnalyzer__ClassAnalyzer_extract_superclass["Woods::RubyAnalyzer::ClassAnalyzer#extract_superclass"]
  Woods__RubyAnalyzer__ClassAnalyzer_body_children["Woods::RubyAnalyzer::ClassAnalyzer#body_children"]
  Woods__RubyAnalyzer__ClassAnalyzer_extract_mixins["Woods::RubyAnalyzer::ClassAnalyzer#extract_mixins"]
  Woods__RubyAnalyzer__ClassAnalyzer_extract_constants["Woods::RubyAnalyzer::ClassAnalyzer#extract_constants"]
  Woods__RubyAnalyzer__ClassAnalyzer_count_methods["Woods::RubyAnalyzer::ClassAnalyzer#count_methods"]
  Woods__RubyAnalyzer__ClassAnalyzer_build_const_name["Woods::RubyAnalyzer::ClassAnalyzer#build_const_name"]
  Woods__RubyAnalyzer__ClassAnalyzer_extract_source["Woods::RubyAnalyzer::ClassAnalyzer#extract_source"]
  Woods__RubyAnalyzer__ClassAnalyzer_build_dependencies["Woods::RubyAnalyzer::ClassAnalyzer#build_dependencies"]
  Woods__RubyAnalyzer__DataFlowAnalyzer["Woods::RubyAnalyzer::DataFlowAnalyzer"]
  Woods__RubyAnalyzer__DataFlowAnalyzer_initialize["Woods::RubyAnalyzer::DataFlowAnalyzer#initialize"]
  Woods__RubyAnalyzer__DataFlowAnalyzer_initialize -->|method_call| Ast__Parser
  Ast__CallSiteExtractor["Ast::CallSiteExtractor"]
  Woods__RubyAnalyzer__DataFlowAnalyzer_initialize -->|method_call| Ast__CallSiteExtractor
  Woods__RubyAnalyzer__DataFlowAnalyzer_annotate["Woods::RubyAnalyzer::DataFlowAnalyzer#annotate"]
  Woods__RubyAnalyzer__DataFlowAnalyzer_detect_transformations["Woods::RubyAnalyzer::DataFlowAnalyzer#detect_transformations"]
  Woods__RubyAnalyzer__DataFlowAnalyzer_categorize["Woods::RubyAnalyzer::DataFlowAnalyzer#categorize"]
  CATEGORY_BY_METHOD["CATEGORY_BY_METHOD"]
  Woods__RubyAnalyzer__DataFlowAnalyzer_categorize -->|method_call| CATEGORY_BY_METHOD
  Woods__RubyAnalyzer__FqnBuilder["Woods::RubyAnalyzer::FqnBuilder"]
  Woods__RubyAnalyzer__FqnBuilder_build_fqn["Woods::RubyAnalyzer::FqnBuilder#build_fqn"]
  Woods__RubyAnalyzer__MermaidRenderer["Woods::RubyAnalyzer::MermaidRenderer"]
  Woods__RubyAnalyzer__MermaidRenderer_render_call_graph["Woods::RubyAnalyzer::MermaidRenderer#render_call_graph"]
  Woods__RubyAnalyzer__MermaidRenderer_render_call_graph -->|method_call| Set
  Woods__RubyAnalyzer__MermaidRenderer_render_dependency_map["Woods::RubyAnalyzer::MermaidRenderer#render_dependency_map"]
  Woods__RubyAnalyzer__MermaidRenderer_render_dependency_map -->|method_call| Set
  Woods__RubyAnalyzer__MermaidRenderer_render_dependency_map -->|method_call| Array
  Woods__RubyAnalyzer__MermaidRenderer_render_dataflow["Woods::RubyAnalyzer::MermaidRenderer#render_dataflow"]
  Woods__RubyAnalyzer__MermaidRenderer_render_dataflow -->|method_call| Set
  Woods__RubyAnalyzer__MermaidRenderer_render_architecture["Woods::RubyAnalyzer::MermaidRenderer#render_architecture"]
  Woods__RubyAnalyzer__MermaidRenderer_render_stats_section["Woods::RubyAnalyzer::MermaidRenderer#render_stats_section"]
  Woods__RubyAnalyzer__MermaidRenderer_render_hubs_section["Woods::RubyAnalyzer::MermaidRenderer#render_hubs_section"]
  Woods__RubyAnalyzer__MermaidRenderer_sanitize_id["Woods::RubyAnalyzer::MermaidRenderer#sanitize_id"]
  Woods__RubyAnalyzer__MermaidRenderer_escape_label["Woods::RubyAnalyzer::MermaidRenderer#escape_label"]
  Woods__RubyAnalyzer__MermaidRenderer_dataflow_shape["Woods::RubyAnalyzer::MermaidRenderer#dataflow_shape"]
  Woods__RubyAnalyzer__MethodAnalyzer["Woods::RubyAnalyzer::MethodAnalyzer"]
  Woods__RubyAnalyzer__MethodAnalyzer -->|include| FqnBuilder
  Woods__RubyAnalyzer__MethodAnalyzer__VisibilityTracker["Woods::RubyAnalyzer::MethodAnalyzer::VisibilityTracker"]
  Woods__RubyAnalyzer__MethodAnalyzer_initialize["Woods::RubyAnalyzer::MethodAnalyzer#initialize"]
  Woods__RubyAnalyzer__MethodAnalyzer_initialize -->|method_call| Ast__Parser
  Woods__RubyAnalyzer__MethodAnalyzer_initialize -->|method_call| Ast__CallSiteExtractor
  Woods__RubyAnalyzer__MethodAnalyzer_analyze["Woods::RubyAnalyzer::MethodAnalyzer#analyze"]
  Woods__RubyAnalyzer__MethodAnalyzer_extract_methods_from_tree["Woods::RubyAnalyzer::MethodAnalyzer#extract_methods_from_tree"]
  Woods__RubyAnalyzer__MethodAnalyzer_process_container_methods["Woods::RubyAnalyzer::MethodAnalyzer#process_container_methods"]
  VisibilityTracker["VisibilityTracker"]
  Woods__RubyAnalyzer__MethodAnalyzer_process_container_methods -->|method_call| VisibilityTracker
  Woods__RubyAnalyzer__MethodAnalyzer_build_method_unit["Woods::RubyAnalyzer::MethodAnalyzer#build_method_unit"]
  Woods__RubyAnalyzer__MethodAnalyzer_build_method_unit -->|method_call| ExtractedUnit
  Woods__RubyAnalyzer__MethodAnalyzer_extract_call_graph["Woods::RubyAnalyzer::MethodAnalyzer#extract_call_graph"]
  Woods__RubyAnalyzer__MethodAnalyzer_build_dependencies["Woods::RubyAnalyzer::MethodAnalyzer#build_dependencies"]
  Woods__RubyAnalyzer__MethodAnalyzer__VisibilityTracker_initialize["Woods::RubyAnalyzer::MethodAnalyzer::VisibilityTracker#initialize"]
  Woods__RubyAnalyzer__MethodAnalyzer__VisibilityTracker_process_send["Woods::RubyAnalyzer::MethodAnalyzer::VisibilityTracker#process_send"]
  VISIBILITY_METHODS["VISIBILITY_METHODS"]
  Woods__RubyAnalyzer__MethodAnalyzer__VisibilityTracker_process_send -->|method_call| VISIBILITY_METHODS
  Woods__RubyAnalyzer__TraceEnricher["Woods::RubyAnalyzer::TraceEnricher"]
  Woods__RubyAnalyzer__TraceEnricher_record["Woods::RubyAnalyzer::TraceEnricher.record"]
  TracePoint["TracePoint"]
  Woods__RubyAnalyzer__TraceEnricher_record -->|method_call| TracePoint
  Woods__RubyAnalyzer__TraceEnricher_merge["Woods::RubyAnalyzer::TraceEnricher.merge"]
  Woods__SessionTracer["Woods::SessionTracer"]
  Woods__SessionTracer__FileStore["Woods::SessionTracer::FileStore"]
  Store["Store"]
  Woods__SessionTracer__FileStore -->|inheritance| Store
  Woods__SessionTracer__FileStore_initialize["Woods::SessionTracer::FileStore#initialize"]
  Woods__SessionTracer__FileStore_initialize -->|method_call| Mutex
  Woods__SessionTracer__FileStore_initialize -->|method_call| FileUtils
  Woods__SessionTracer__FileStore_record["Woods::SessionTracer::FileStore#record"]
  Woods__SessionTracer__FileStore_record -->|method_call| File
  Woods__SessionTracer__FileStore_record -->|method_call| File_readlines
  Woods__SessionTracer__FileStore_read["Woods::SessionTracer::FileStore#read"]
  Woods__SessionTracer__FileStore_read -->|method_call| File
  Woods__SessionTracer__FileStore_read -->|method_call| FileUtils
  Woods__SessionTracer__FileStore_read -->|method_call| JSON
  Woods__SessionTracer__FileStore_sessions["Woods::SessionTracer::FileStore#sessions"]
  File_mtime_to_f["File.mtime.to_f"]
  Woods__SessionTracer__FileStore_sessions -->|method_call| File_mtime_to_f
  File_mtime["File.mtime"]
  Woods__SessionTracer__FileStore_sessions -->|method_call| File_mtime
  Woods__SessionTracer__FileStore_sessions -->|method_call| File
  Woods__SessionTracer__FileStore_clear["Woods::SessionTracer::FileStore#clear"]
  Woods__SessionTracer__FileStore_clear -->|method_call| FileUtils
  Woods__SessionTracer__FileStore_clear_all["Woods::SessionTracer::FileStore#clear_all"]
  Woods__SessionTracer__FileStore_clear_all -->|method_call| File
  Woods__SessionTracer__FileStore_session_path["Woods::SessionTracer::FileStore#session_path"]
  Woods__SessionTracer__FileStore_session_path -->|method_call| File
  Woods__SessionTracer__FileStore_session_files["Woods::SessionTracer::FileStore#session_files"]
  Woods__SessionTracer__FileStore_session_files -->|method_call| Dir
  Woods__SessionTracer__FileStore_with_store_lock["Woods::SessionTracer::FileStore#with_store_lock"]
  Woods__SessionTracer__FileStore_with_store_lock -->|method_call| File
  Woods__SessionTracer__FileStore_legacy_session_path["Woods::SessionTracer::FileStore#legacy_session_path"]
  Woods__SessionTracer__FileStore_legacy_session_path -->|method_call| File
  Woods__SessionTracer__FileStore_migrate_legacy_session_["Woods::SessionTracer::FileStore#migrate_legacy_session!"]
  Woods__SessionTracer__FileStore_migrate_legacy_session_ -->|method_call| File
  Woods__SessionTracer__FileStore_migrate_legacy_session_ -->|method_call| FileUtils
  Woods__SessionTracer__FileStore_migrate_legacy_sessions_["Woods::SessionTracer::FileStore#migrate_legacy_sessions!"]
  Woods__SessionTracer__FileStore_migrate_legacy_sessions_ -->|method_call| File
  Woods__SessionTracer__FileStore_atomic_replace["Woods::SessionTracer::FileStore#atomic_replace"]
  Woods__SessionTracer__FileStore_atomic_replace -->|method_call| Tempfile
  Woods__SessionTracer__FileStore_atomic_replace -->|method_call| File
  Woods__SessionTracer__FileStore_fsync_parent["Woods::SessionTracer::FileStore#fsync_parent"]
  Woods__SessionTracer__FileStore_fsync_parent -->|method_call| File
  Woods__SessionTracer__FileStore_expired_["Woods::SessionTracer::FileStore#expired?"]
  Woods__SessionTracer__FileStore_prune_expired_["Woods::SessionTracer::FileStore#prune_expired!"]
  Woods__SessionTracer__FileStore_prune_expired_ -->|method_call| FileUtils
  Woods__SessionTracer__FileStore_prune_sessions_["Woods::SessionTracer::FileStore#prune_sessions!"]
  Woods__SessionTracer__FileStore_prune_sessions_ -->|method_call| File_mtime_to_f
  Woods__SessionTracer__FileStore_prune_sessions_ -->|method_call| File_mtime
  Woods__SessionTracer__FileStore_prune_sessions_ -->|method_call| File
  Woods__SessionTracer__FileStore_prune_sessions_ -->|method_call| FileUtils
  Woods__SessionTracer__FileStore_validate_limit_["Woods::SessionTracer::FileStore#validate_limit!"]
  Woods__SessionTracer__Middleware["Woods::SessionTracer::Middleware"]
  Woods__SessionTracer__Middleware_initialize["Woods::SessionTracer::Middleware#initialize"]
  REQUIRED_STORE_METHODS["REQUIRED_STORE_METHODS"]
  Woods__SessionTracer__Middleware_initialize -->|method_call| REQUIRED_STORE_METHODS
  Woods__SessionTracer__Middleware_call["Woods::SessionTracer::Middleware#call"]
  Woods__SessionTracer__Middleware_call -->|method_call| Process
  Woods__SessionTracer__Middleware_call -->|method_call| Process_clock_gettime
  Woods__SessionTracer__Middleware_record_request["Woods::SessionTracer::Middleware#record_request"]
  Woods__SessionTracer__Middleware_extract_session_id["Woods::SessionTracer::Middleware#extract_session_id"]
  Woods__SessionTracer__Middleware_excluded_["Woods::SessionTracer::Middleware#excluded?"]
  Woods__SessionTracer__Middleware_classify_controller["Woods::SessionTracer::Middleware#classify_controller"]
  Woods__SessionTracer__Middleware_extract_format["Woods::SessionTracer::Middleware#extract_format"]
  Woods__SessionTracer__RedisStore["Woods::SessionTracer::RedisStore"]
  Woods__SessionTracer__RedisStore -->|inheritance| Store
  Woods__SessionTracer__RedisStore_initialize["Woods::SessionTracer::RedisStore#initialize"]
  Woods__SessionTracer__RedisStore_record["Woods::SessionTracer::RedisStore#record"]
  Woods__SessionTracer__RedisStore_read["Woods::SessionTracer::RedisStore#read"]
  Woods__SessionTracer__RedisStore_read -->|method_call| JSON
  Woods__SessionTracer__RedisStore_sessions["Woods::SessionTracer::RedisStore#sessions"]
  Woods__SessionTracer__RedisStore_clear["Woods::SessionTracer::RedisStore#clear"]
  Woods__SessionTracer__RedisStore_clear_all["Woods::SessionTracer::RedisStore#clear_all"]
  Woods__SessionTracer__RedisStore_session_key["Woods::SessionTracer::RedisStore#session_key"]
  Woods__SessionTracer__RedisStore_prune_sessions["Woods::SessionTracer::RedisStore#prune_sessions"]
  Woods__SessionTracer__RedisStore_recency_key["Woods::SessionTracer::RedisStore#recency_key"]
  Woods__SessionTracer__SessionFlowAssembler["Woods::SessionTracer::SessionFlowAssembler"]
  Woods__SessionTracer__SessionFlowAssembler_initialize["Woods::SessionTracer::SessionFlowAssembler#initialize"]
  Woods__SessionTracer__SessionFlowAssembler_assemble["Woods::SessionTracer::SessionFlowAssembler#assemble"]
  Woods__SessionTracer__SessionFlowAssembler_assemble -->|method_call| Set
  Woods__SessionTracer__SessionFlowAssembler_build_step["Woods::SessionTracer::SessionFlowAssembler#build_step"]
  Woods__SessionTracer__SessionFlowAssembler_resolve_dependencies["Woods::SessionTracer::SessionFlowAssembler#resolve_dependencies"]
  ASYNC_TYPES["ASYNC_TYPES"]
  Woods__SessionTracer__SessionFlowAssembler_resolve_dependencies -->|method_call| ASYNC_TYPES
  Woods__SessionTracer__SessionFlowAssembler_expand_transitive["Woods::SessionTracer::SessionFlowAssembler#expand_transitive"]
  Woods__SessionTracer__SessionFlowAssembler_unit_summary["Woods::SessionTracer::SessionFlowAssembler#unit_summary"]
  Woods__SessionTracer__SessionFlowAssembler_apply_budget["Woods::SessionTracer::SessionFlowAssembler#apply_budget"]
  Woods__SessionTracer__SessionFlowAssembler_apply_budget -->|method_call| TokenUtils
  Woods__SessionTracer__SessionFlowAssembler_estimate_tokens["Woods::SessionTracer::SessionFlowAssembler#estimate_tokens"]
  TokenUtils_estimate_tokens["TokenUtils.estimate_tokens"]
  Woods__SessionTracer__SessionFlowAssembler_estimate_tokens -->|method_call| TokenUtils_estimate_tokens
  Woods__SessionTracer__SessionFlowAssembler_estimate_tokens -->|method_call| TokenUtils
  Woods__SessionTracer__SessionFlowAssembler_budgeted_document["Woods::SessionTracer::SessionFlowAssembler#budgeted_document"]
  SessionFlowDocument["SessionFlowDocument"]
  Woods__SessionTracer__SessionFlowAssembler_budgeted_document -->|method_call| SessionFlowDocument
  Woods__SessionTracer__SessionFlowAssembler_rendered_tokens["Woods::SessionTracer::SessionFlowAssembler#rendered_tokens"]
  Woods__SessionTracer__SessionFlowAssembler_rendered_tokens -->|method_call| SessionFlowDocument
  Woods__SessionTracer__SessionFlowAssembler_rendered_tokens -->|method_call| TokenUtils
  Woods__SessionTracer__SessionFlowAssembler_shrink_source_pool_["Woods::SessionTracer::SessionFlowAssembler#shrink_source_pool?"]
  Woods__SessionTracer__SessionFlowAssembler_truncatable_source_["Woods::SessionTracer::SessionFlowAssembler#truncatable_source?"]
  Woods__SessionTracer__SessionFlowAssembler_empty_document["Woods::SessionTracer::SessionFlowAssembler#empty_document"]
  Woods__SessionTracer__SessionFlowAssembler_empty_document -->|method_call| SessionFlowDocument
  Woods__SessionTracer__SessionFlowDocument["Woods::SessionTracer::SessionFlowDocument"]
  Woods__SessionTracer__SessionFlowDocument_initialize["Woods::SessionTracer::SessionFlowDocument#initialize"]
  Woods__SessionTracer__SessionFlowDocument_initialize -->|method_call| Time_now_utc
  Woods__SessionTracer__SessionFlowDocument_initialize -->|method_call| Time_now
  Woods__SessionTracer__SessionFlowDocument_initialize -->|method_call| Time
  Woods__SessionTracer__SessionFlowDocument_budget_exceeded_["Woods::SessionTracer::SessionFlowDocument#budget_exceeded?"]
  Woods__SessionTracer__SessionFlowDocument_to_h["Woods::SessionTracer::SessionFlowDocument#to_h"]
  Woods__SessionTracer__SessionFlowDocument_from_h["Woods::SessionTracer::SessionFlowDocument.from_h"]
  Woods__SessionTracer__SessionFlowDocument_to_markdown["Woods::SessionTracer::SessionFlowDocument#to_markdown"]
  Woods__SessionTracer__SessionFlowDocument_to_context["Woods::SessionTracer::SessionFlowDocument#to_context"]
  Woods__SessionTracer__SessionFlowDocument_escape_attribute["Woods::SessionTracer::SessionFlowDocument#escape_attribute"]
  Woods__SessionTracer__SessionFlowDocument_escape_content["Woods::SessionTracer::SessionFlowDocument#escape_content"]
  Woods__SessionTracer__SessionFlowDocument_deep_symbolize_keys["Woods::SessionTracer::SessionFlowDocument.deep_symbolize_keys"]
  Woods__SessionTracer__SolidCacheCoordination["Woods::SessionTracer::SolidCacheCoordination"]
  Woods__SessionTracer__SolidCacheCoordination__BackendError["Woods::SessionTracer::SolidCacheCoordination::BackendError"]
  Woods__SessionTracer__SolidCacheCoordination__BackendError -->|inheritance| Woods__Error
  Woods__SessionTracer__SolidCacheCoordination_initialize["Woods::SessionTracer::SolidCacheCoordination#initialize"]
  Woods__SessionTracer__SolidCacheCoordination_read["Woods::SessionTracer::SolidCacheCoordination#read"]
  Woods__SessionTracer__SolidCacheCoordination_write["Woods::SessionTracer::SolidCacheCoordination#write"]
  Woods__SessionTracer__SolidCacheCoordination_delete["Woods::SessionTracer::SolidCacheCoordination#delete"]
  Woods__SessionTracer__SolidCacheCoordination_increment["Woods::SessionTracer::SolidCacheCoordination#increment"]
  Woods__SessionTracer__SolidCacheCoordination_write_if_absent["Woods::SessionTracer::SolidCacheCoordination#write_if_absent"]
  Woods__SessionTracer__SolidCacheCoordination_delete_if_equal["Woods::SessionTracer::SolidCacheCoordination#delete_if_equal"]
  Woods__SessionTracer__SolidCacheCoordination_with_operation["Woods::SessionTracer::SolidCacheCoordination#with_operation"]
  Woods__SessionTracer__SolidCacheCoordination_locked_compare_and_delete["Woods::SessionTracer::SolidCacheCoordination#locked_compare_and_delete"]
  Woods__SessionTracer__SolidCacheCoordination_delete_expired_entry["Woods::SessionTracer::SolidCacheCoordination#delete_expired_entry"]
  Woods__SessionTracer__SolidCacheCoordination_attempt_insert_["Woods::SessionTracer::SolidCacheCoordination#attempt_insert?"]
  Woods__SessionTracer__SolidCacheCoordination_clear_expired_entry_["Woods::SessionTracer::SolidCacheCoordination#clear_expired_entry?"]
  Woods__SessionTracer__SolidCacheCoordination_cache_entry["Woods::SessionTracer::SolidCacheCoordination#cache_entry"]
  ActiveSupport__Cache__Entry["ActiveSupport::Cache::Entry"]
  Woods__SessionTracer__SolidCacheCoordination_cache_entry -->|method_call| ActiveSupport__Cache__Entry
  Woods__SessionTracer__SolidCacheCoordination_insert_entry["Woods::SessionTracer::SolidCacheCoordination#insert_entry"]
  Woods__SessionTracer__SolidCacheCoordination_inserted_["Woods::SessionTracer::SolidCacheCoordination#inserted?"]
  Woods__SessionTracer__SolidCacheCoordination_routed_read["Woods::SessionTracer::SolidCacheCoordination#routed_read"]
  SolidCache__Entry["SolidCache::Entry"]
  Woods__SessionTracer__SolidCacheCoordination_routed_read -->|method_call| SolidCache__Entry
  Woods__SessionTracer__SolidCacheCoordination_routed_write["Woods::SessionTracer::SolidCacheCoordination#routed_write"]
  Woods__SessionTracer__SolidCacheCoordination_routed_delete["Woods::SessionTracer::SolidCacheCoordination#routed_delete"]
  Woods__SessionTracer__SolidCacheCoordination_routed_delete -->|method_call| SolidCache__Entry
  Woods__SessionTracer__SolidCacheCoordination_backend_result_["Woods::SessionTracer::SolidCacheCoordination#backend_result!"]
  Woods__SessionTracer__SolidCacheStore["Woods::SessionTracer::SolidCacheStore"]
  Woods__SessionTracer__SolidCacheStore -->|inheritance| Store
  Woods__SessionTracer__SolidCacheStore__AtomicIncrementRequired["Woods::SessionTracer::SolidCacheStore::AtomicIncrementRequired"]
  Woods__SessionTracer__SolidCacheStore__AtomicIncrementRequired -->|inheritance| Woods__Error
  Woods__SessionTracer__SolidCacheStore__BackendWriteError["Woods::SessionTracer::SolidCacheStore::BackendWriteError"]
  Woods__SessionTracer__SolidCacheStore__BackendWriteError -->|inheritance| Woods__Error
  Woods__SessionTracer__SolidCacheStore__DirectoryContentionError["Woods::SessionTracer::SolidCacheStore::DirectoryContentionError"]
  Woods__SessionTracer__SolidCacheStore__DirectoryContentionError -->|inheritance| Woods__Error
  Woods__SessionTracer__SolidCacheStore__ReadContentionError["Woods::SessionTracer::SolidCacheStore::ReadContentionError"]
  Woods__SessionTracer__SolidCacheStore__ReadContentionError -->|inheritance| Woods__Error
  Woods__SessionTracer__SolidCacheStore_initialize["Woods::SessionTracer::SolidCacheStore#initialize"]
  SolidCacheCoordination["SolidCacheCoordination"]
  Woods__SessionTracer__SolidCacheStore_initialize -->|method_call| SolidCacheCoordination
  Woods__SessionTracer__SolidCacheStore_record["Woods::SessionTracer::SolidCacheStore#record"]
  Woods__SessionTracer__SolidCacheStore_record -->|method_call| JSON
  Woods__SessionTracer__SolidCacheStore_read["Woods::SessionTracer::SolidCacheStore#read"]
  READ_ATTEMPTS["READ_ATTEMPTS"]
  Woods__SessionTracer__SolidCacheStore_read -->|method_call| READ_ATTEMPTS
  Woods__SessionTracer__SolidCacheStore_sessions["Woods::SessionTracer::SolidCacheStore#sessions"]
  Woods__SessionTracer__SolidCacheStore_clear["Woods::SessionTracer::SolidCacheStore#clear"]
  Woods__SessionTracer__SolidCacheStore_clear_all["Woods::SessionTracer::SolidCacheStore#clear_all"]
  Woods__SessionTracer__SolidCacheStore_publish_record["Woods::SessionTracer::SolidCacheStore#publish_record"]
  Woods__SessionTracer__SolidCacheStore_publish_record -->|method_call| JSON
  Woods__SessionTracer__SolidCacheStore_read_snapshot["Woods::SessionTracer::SolidCacheStore#read_snapshot"]
  Woods__SessionTracer__SolidCacheStore_increment_["Woods::SessionTracer::SolidCacheStore#increment!"]
  Woods__SessionTracer__SolidCacheStore_ensure_counter_present_["Woods::SessionTracer::SolidCacheStore#ensure_counter_present!"]
  Woods__SessionTracer__SolidCacheStore_counter_value["Woods::SessionTracer::SolidCacheStore#counter_value"]
  Woods__SessionTracer__SolidCacheStore_integer_value["Woods::SessionTracer::SolidCacheStore#integer_value"]
  Woods__SessionTracer__SolidCacheStore_recover_counter_["Woods::SessionTracer::SolidCacheStore#recover_counter!"]
  COUNTER_RECOVERY_ATTEMPTS["COUNTER_RECOVERY_ATTEMPTS"]
  Woods__SessionTracer__SolidCacheStore_recover_counter_ -->|method_call| COUNTER_RECOVERY_ATTEMPTS
  Woods__SessionTracer__SolidCacheStore_counter_floor["Woods::SessionTracer::SolidCacheStore#counter_floor"]
  Woods__SessionTracer__SolidCacheStore_epoch_recovery_floor["Woods::SessionTracer::SolidCacheStore#epoch_recovery_floor"]
  Woods__SessionTracer__SolidCacheStore_ring_sequence_floor["Woods::SessionTracer::SolidCacheStore#ring_sequence_floor"]
  Woods__SessionTracer__SolidCacheStore_directory_sequence_floor["Woods::SessionTracer::SolidCacheStore#directory_sequence_floor"]
  Woods__SessionTracer__SolidCacheStore_write_["Woods::SessionTracer::SolidCacheStore#write!"]
  Woods__SessionTracer__SolidCacheStore_publish_current_slot_["Woods::SessionTracer::SolidCacheStore#publish_current_slot?"]
  Woods__SessionTracer__SolidCacheStore_write_newer_slot["Woods::SessionTracer::SolidCacheStore#write_newer_slot"]
  RECORD_PUBLISH_ATTEMPTS["RECORD_PUBLISH_ATTEMPTS"]
  Woods__SessionTracer__SolidCacheStore_write_newer_slot -->|method_call| RECORD_PUBLISH_ATTEMPTS
  Woods__SessionTracer__SolidCacheStore_write_newer_slot -->|method_call| Thread
  Woods__SessionTracer__SolidCacheStore_write_options["Woods::SessionTracer::SolidCacheStore#write_options"]
  Woods__SessionTracer__SolidCacheStore_parse_record["Woods::SessionTracer::SolidCacheStore#parse_record"]
  Woods__SessionTracer__SolidCacheStore_parse_record -->|method_call| JSON
  Woods__SessionTracer__SolidCacheStore_payload_sequence["Woods::SessionTracer::SolidCacheStore#payload_sequence"]
  Woods__SessionTracer__SolidCacheStore_payload_sequence -->|method_call| JSON
  Woods__SessionTracer__SolidCacheStore_payload_token["Woods::SessionTracer::SolidCacheStore#payload_token"]
  Woods__SessionTracer__SolidCacheStore_payload_token -->|method_call| JSON
  Woods__SessionTracer__SolidCacheStore_admit_session["Woods::SessionTracer::SolidCacheStore#admit_session"]
  DIRECTORY_CLAIM_ATTEMPTS["DIRECTORY_CLAIM_ATTEMPTS"]
  Woods__SessionTracer__SolidCacheStore_admit_session -->|method_call| DIRECTORY_CLAIM_ATTEMPTS
  Woods__SessionTracer__SolidCacheStore_build_admission["Woods::SessionTracer::SolidCacheStore#build_admission"]
  Woods__SessionTracer__SolidCacheStore_reclaim_active_mapping["Woods::SessionTracer::SolidCacheStore#reclaim_active_mapping"]
  Woods__SessionTracer__SolidCacheStore_finalize_admission["Woods::SessionTracer::SolidCacheStore#finalize_admission"]
  Woods__SessionTracer__SolidCacheStore_claim_directory_slot["Woods::SessionTracer::SolidCacheStore#claim_directory_slot"]
  Woods__SessionTracer__SolidCacheStore_claim_directory_slot -->|method_call| DIRECTORY_CLAIM_ATTEMPTS
  Woods__SessionTracer__SolidCacheStore_claim_reclaimable_slot["Woods::SessionTracer::SolidCacheStore#claim_reclaimable_slot"]
  Woods__SessionTracer__SolidCacheStore_oldest_active_membership["Woods::SessionTracer::SolidCacheStore#oldest_active_membership"]
  Woods__SessionTracer__SolidCacheStore_claim_directory_slot_["Woods::SessionTracer::SolidCacheStore#claim_directory_slot?"]
  Woods__SessionTracer__SolidCacheStore_active_memberships["Woods::SessionTracer::SolidCacheStore#active_memberships"]
  Woods__SessionTracer__SolidCacheStore_directory_slots["Woods::SessionTracer::SolidCacheStore#directory_slots"]
  DirectorySlot["DirectorySlot"]
  Woods__SessionTracer__SolidCacheStore_directory_slots -->|method_call| DirectorySlot
  Woods__SessionTracer__SolidCacheStore_owned_membership["Woods::SessionTracer::SolidCacheStore#owned_membership"]
  Woods__SessionTracer__SolidCacheStore_active_membership["Woods::SessionTracer::SolidCacheStore#active_membership"]
  Woods__SessionTracer__SolidCacheStore_stored_membership["Woods::SessionTracer::SolidCacheStore#stored_membership"]
  Woods__SessionTracer__SolidCacheStore_parse_membership["Woods::SessionTracer::SolidCacheStore#parse_membership"]
  Woods__SessionTracer__SolidCacheStore_parse_membership -->|method_call| JSON
  Woods__SessionTracer__SolidCacheStore_valid_membership_["Woods::SessionTracer::SolidCacheStore#valid_membership?"]
  Woods__SessionTracer__SolidCacheStore_valid_membership_identity_["Woods::SessionTracer::SolidCacheStore#valid_membership_identity?"]
  Woods__SessionTracer__SolidCacheStore_valid_membership_epoch_["Woods::SessionTracer::SolidCacheStore#valid_membership_epoch?"]
  Woods__SessionTracer__SolidCacheStore_valid_membership_position_["Woods::SessionTracer::SolidCacheStore#valid_membership_position?"]
  Woods__SessionTracer__SolidCacheStore_current_membership_["Woods::SessionTracer::SolidCacheStore#current_membership?"]
  Woods__SessionTracer__SolidCacheStore_active_current_membership_["Woods::SessionTracer::SolidCacheStore#active_current_membership?"]
  Woods__SessionTracer__SolidCacheStore_retire_membership["Woods::SessionTracer::SolidCacheStore#retire_membership"]
  Woods__SessionTracer__SolidCacheStore_refresh_activity_["Woods::SessionTracer::SolidCacheStore#refresh_activity!"]
  Woods__SessionTracer__SolidCacheStore_cleanup_slot_records["Woods::SessionTracer::SolidCacheStore#cleanup_slot_records"]
  Woods__SessionTracer__SolidCacheStore_indexed_membership_["Woods::SessionTracer::SolidCacheStore#indexed_membership?"]
  Woods__SessionTracer__SolidCacheStore_release_directory_slot["Woods::SessionTracer::SolidCacheStore#release_directory_slot"]
  Woods__SessionTracer__SolidCacheStore_atomic_delete_if_equal["Woods::SessionTracer::SolidCacheStore#atomic_delete_if_equal"]
  Woods__SessionTracer__SolidCacheStore_atomic_write_if_absent["Woods::SessionTracer::SolidCacheStore#atomic_write_if_absent"]
  Woods__SessionTracer__SolidCacheStore_solid_cache_backend_["Woods::SessionTracer::SolidCacheStore#solid_cache_backend?"]
  Woods__SessionTracer__SolidCacheStore_serialized_membership["Woods::SessionTracer::SolidCacheStore#serialized_membership"]
  Woods__SessionTracer__SolidCacheStore_serialized_membership -->|method_call| JSON
  Woods__SessionTracer__SolidCacheStore_stale_sequence_["Woods::SessionTracer::SolidCacheStore#stale_sequence?"]
  Woods__SessionTracer__SolidCacheStore_stale_index_sequence_["Woods::SessionTracer::SolidCacheStore#stale_index_sequence?"]
  Woods__SessionTracer__SolidCacheStore_current_epoch["Woods::SessionTracer::SolidCacheStore#current_epoch"]
  Woods__SessionTracer__SolidCacheStore_active_key["Woods::SessionTracer::SolidCacheStore#active_key"]
  Woods__SessionTracer__SolidCacheStore_activity_key["Woods::SessionTracer::SolidCacheStore#activity_key"]
  Woods__SessionTracer__SolidCacheStore_slot_sequence_key["Woods::SessionTracer::SolidCacheStore#slot_sequence_key"]
  Woods__SessionTracer__SolidCacheStore_record_key["Woods::SessionTracer::SolidCacheStore#record_key"]
  Woods__SessionTracer__SolidCacheStore_record_ring_key["Woods::SessionTracer::SolidCacheStore#record_ring_key"]
  Woods__SessionTracer__SolidCacheStore_epoch_key["Woods::SessionTracer::SolidCacheStore#epoch_key"]
  Woods__SessionTracer__SolidCacheStore_index_sequence_key["Woods::SessionTracer::SolidCacheStore#index_sequence_key"]
  Woods__SessionTracer__SolidCacheStore_index_slot_key["Woods::SessionTracer::SolidCacheStore#index_slot_key"]
  Woods__SessionTracer__SolidCacheStore_positive_integer_["Woods::SessionTracer::SolidCacheStore#positive_integer!"]
  Woods__SessionTracer__Store["Woods::SessionTracer::Store"]
  Woods__SessionTracer__Store_record["Woods::SessionTracer::Store#record"]
  Woods__SessionTracer__Store_read["Woods::SessionTracer::Store#read"]
  Woods__SessionTracer__Store_sessions["Woods::SessionTracer::Store#sessions"]
  Woods__SessionTracer__Store_clear["Woods::SessionTracer::Store#clear"]
  Woods__SessionTracer__Store_clear_all["Woods::SessionTracer::Store#clear_all"]
  Woods__SessionTracer__Store_sanitize_session_id["Woods::SessionTracer::Store#sanitize_session_id"]
  Woods__SessionTracer__Store_restore_session_id["Woods::SessionTracer::Store#restore_session_id"]
  Woods__SessionTracer__Store_restore_session_id -->|method_call| Base64
  Woods__SessionTracer__Store_session_summary["Woods::SessionTracer::Store#session_summary"]
  Woods__Storage["Woods::Storage"]
  Woods__Storage__GraphStore["Woods::Storage::GraphStore"]
  Woods__Storage__GraphStore__Interface["Woods::Storage::GraphStore::Interface"]
  Woods__Storage__GraphStore__Memory -->|include| Interface
  Woods__Storage__GraphStore__Interface_dependencies_of["Woods::Storage::GraphStore::Interface#dependencies_of"]
  Woods__Storage__GraphStore__Interface_dependents_of["Woods::Storage::GraphStore::Interface#dependents_of"]
  Woods__Storage__GraphStore__Interface_affected_by["Woods::Storage::GraphStore::Interface#affected_by"]
  Woods__Storage__GraphStore__Interface_by_type["Woods::Storage::GraphStore::Interface#by_type"]
  Woods__Storage__GraphStore__Interface_pagerank["Woods::Storage::GraphStore::Interface#pagerank"]
  Woods__Storage__GraphStore__Interface_durable_["Woods::Storage::GraphStore::Interface#durable?"]
  Woods__Storage__GraphStore__Memory_initialize["Woods::Storage::GraphStore::Memory#initialize"]
  Woods__Storage__GraphStore__Memory_initialize -->|method_call| DependencyGraph
  Woods__Storage__GraphStore__Memory_register["Woods::Storage::GraphStore::Memory#register"]
  Woods__Storage__GraphStore__Memory_replace_graph["Woods::Storage::GraphStore::Memory#replace_graph"]
  Woods__Storage__GraphStore__Memory_dependencies_of["Woods::Storage::GraphStore::Memory#dependencies_of"]
  Woods__Storage__GraphStore__Memory_dependents_of["Woods::Storage::GraphStore::Memory#dependents_of"]
  Woods__Storage__GraphStore__Memory_affected_by["Woods::Storage::GraphStore::Memory#affected_by"]
  Woods__Storage__GraphStore__Memory_by_type["Woods::Storage::GraphStore::Memory#by_type"]
  Woods__Storage__GraphStore__Memory_pagerank["Woods::Storage::GraphStore::Memory#pagerank"]
  Woods__Storage__GraphStore__Memory_durable_["Woods::Storage::GraphStore::Memory#durable?"]
  Woods__Storage__InapplicableBackend["Woods::Storage::InapplicableBackend"]
  Woods__Storage__InapplicableBackend -->|inheritance| Woods__Error
  Woods__Storage__MetadataStore["Woods::Storage::MetadataStore"]
  Woods__Storage__MetadataStore__Interface["Woods::Storage::MetadataStore::Interface"]
  Woods__Storage__MetadataStore__InMemory["Woods::Storage::MetadataStore::InMemory"]
  Woods__Storage__MetadataStore__InMemory -->|include| Interface
  Woods__Storage__MetadataStore__SQLite["Woods::Storage::MetadataStore::SQLite"]
  Woods__Storage__MetadataStore__SQLite -->|include| Interface
  Woods__Storage__MetadataStore__Interface_store["Woods::Storage::MetadataStore::Interface#store"]
  Woods__Storage__MetadataStore__Interface_find["Woods::Storage::MetadataStore::Interface#find"]
  Woods__Storage__MetadataStore__Interface_find_batch["Woods::Storage::MetadataStore::Interface#find_batch"]
  Woods__Storage__MetadataStore__Interface_find_by_type["Woods::Storage::MetadataStore::Interface#find_by_type"]
  Woods__Storage__MetadataStore__Interface_search["Woods::Storage::MetadataStore::Interface#search"]
  Woods__Storage__MetadataStore__Interface_all_identifiers["Woods::Storage::MetadataStore::Interface#all_identifiers"]
  Woods__Storage__MetadataStore__Interface_delete["Woods::Storage::MetadataStore::Interface#delete"]
  Woods__Storage__MetadataStore__Interface_count["Woods::Storage::MetadataStore::Interface#count"]
  Woods__Storage__MetadataStore__Interface_validate_search_fields_["Woods::Storage::MetadataStore::Interface#validate_search_fields!"]
  Woods__Storage__MetadataStore__InMemory_initialize["Woods::Storage::MetadataStore::InMemory#initialize"]
  Woods__Storage__MetadataStore__InMemory_store["Woods::Storage::MetadataStore::InMemory#store"]
  Woods__Storage__MetadataStore__InMemory_find["Woods::Storage::MetadataStore::InMemory#find"]
  Woods__Storage__MetadataStore__InMemory_find_batch["Woods::Storage::MetadataStore::InMemory#find_batch"]
  Woods__Storage__MetadataStore__InMemory_find_by_type["Woods::Storage::MetadataStore::InMemory#find_by_type"]
  Woods__Storage__MetadataStore__InMemory_search["Woods::Storage::MetadataStore::InMemory#search"]
  Woods__Storage__MetadataStore__InMemory_search -->|method_call| JSON
  Woods__Storage__MetadataStore__InMemory_all_identifiers["Woods::Storage::MetadataStore::InMemory#all_identifiers"]
  Woods__Storage__MetadataStore__InMemory_delete["Woods::Storage::MetadataStore::InMemory#delete"]
  Woods__Storage__MetadataStore__InMemory_count["Woods::Storage::MetadataStore::InMemory#count"]
  Woods__Storage__MetadataStore__InMemory_each_entry["Woods::Storage::MetadataStore::InMemory#each_entry"]
  Woods__Storage__MetadataStore__InMemory_bulk_load["Woods::Storage::MetadataStore::InMemory#bulk_load"]
  Woods__Storage__MetadataStore__InMemory_clear_["Woods::Storage::MetadataStore::InMemory#clear!"]
  Woods__Storage__MetadataStore__InMemory_stringify_keys["Woods::Storage::MetadataStore::InMemory#stringify_keys"]
  Woods__Storage__MetadataStore__SQLite_initialize["Woods::Storage::MetadataStore::SQLite#initialize"]
  Woods__Storage__MetadataStore__SQLite_initialize -->|method_call| FileUtils
  Woods__Storage__MetadataStore__SQLite_initialize -->|method_call| SQLite3__Database
  Woods__Storage__MetadataStore__SQLite_store["Woods::Storage::MetadataStore::SQLite#store"]
  Woods__Storage__MetadataStore__SQLite_store -->|method_call| JSON
  Woods__Storage__MetadataStore__SQLite_find["Woods::Storage::MetadataStore::SQLite#find"]
  Woods__Storage__MetadataStore__SQLite_find -->|method_call| JSON
  Woods__Storage__MetadataStore__SQLite_find_batch["Woods::Storage::MetadataStore::SQLite#find_batch"]
  Array_new["Array.new"]
  Woods__Storage__MetadataStore__SQLite_find_batch -->|method_call| Array_new
  Woods__Storage__MetadataStore__SQLite_find_batch -->|method_call| Array
  Woods__Storage__MetadataStore__SQLite_find_batch -->|method_call| JSON
  Woods__Storage__MetadataStore__SQLite_find_by_type["Woods::Storage::MetadataStore::SQLite#find_by_type"]
  Woods__Storage__MetadataStore__SQLite_search["Woods::Storage::MetadataStore::SQLite#search"]
  Woods__Storage__MetadataStore__SQLite_search -->|method_call| Array
  Woods__Storage__MetadataStore__SQLite_all_identifiers["Woods::Storage::MetadataStore::SQLite#all_identifiers"]
  Woods__Storage__MetadataStore__SQLite_delete["Woods::Storage::MetadataStore::SQLite#delete"]
  Woods__Storage__MetadataStore__SQLite_count["Woods::Storage::MetadataStore::SQLite#count"]
  Woods__Storage__MetadataStore__SQLite_escape_like["Woods::Storage::MetadataStore::SQLite#escape_like"]
  Woods__Storage__MetadataStore__SQLite_parse_row["Woods::Storage::MetadataStore::SQLite#parse_row"]
  Woods__Storage__MetadataStore__SQLite_parse_row -->|method_call| JSON
  Woods__Storage__MetadataStore__SQLite_create_table["Woods::Storage::MetadataStore::SQLite#create_table"]
  Woods__Storage__VectorStore["Woods::Storage::VectorStore"]
  Woods__Storage__VectorStore__Pgvector["Woods::Storage::VectorStore::Pgvector"]
  Woods__Storage__VectorStore__Pgvector -->|include| Interface
  Woods__Storage__VectorStore__Pgvector_initialize["Woods::Storage::VectorStore::Pgvector#initialize"]
  Woods__Storage__VectorStore__Pgvector_ensure_schema_["Woods::Storage::VectorStore::Pgvector#ensure_schema!"]
  Woods__Storage__VectorStore__Pgvector_store["Woods::Storage::VectorStore::Pgvector#store"]
  Woods__Storage__VectorStore__Pgvector_store_batch["Woods::Storage::VectorStore::Pgvector#store_batch"]
  Woods__Storage__VectorStore__Pgvector_search["Woods::Storage::VectorStore::Pgvector#search"]
  Woods__Storage__VectorStore__Pgvector_stored_dimensions["Woods::Storage::VectorStore::Pgvector#stored_dimensions"]
  Woods__Storage__VectorStore__Pgvector_each_id["Woods::Storage::VectorStore::Pgvector#each_id"]
  Woods__Storage__VectorStore__Pgvector_delete["Woods::Storage::VectorStore::Pgvector#delete"]
  Woods__Storage__VectorStore__Pgvector_delete_by_filter["Woods::Storage::VectorStore::Pgvector#delete_by_filter"]
  Woods__Storage__VectorStore__Pgvector_count["Woods::Storage::VectorStore::Pgvector#count"]
  Woods__Storage__VectorStore__Pgvector_normalize_dimensions["Woods::Storage::VectorStore::Pgvector#normalize_dimensions"]
  Woods__Storage__VectorStore__Pgvector_validate_identifier_["Woods::Storage::VectorStore::Pgvector#validate_identifier!"]
  TABLE_NAME_PATTERN["TABLE_NAME_PATTERN"]
  Woods__Storage__VectorStore__Pgvector_validate_identifier_ -->|method_call| TABLE_NAME_PATTERN
  Woods__Storage__VectorStore__Pgvector_quote_identifier["Woods::Storage::VectorStore::Pgvector#quote_identifier"]
  Woods__Storage__VectorStore__Pgvector_qualified_table["Woods::Storage::VectorStore::Pgvector#qualified_table"]
  Woods__Storage__VectorStore__Pgvector_schema_sql["Woods::Storage::VectorStore::Pgvector#schema_sql"]
  Woods__Storage__VectorStore__Pgvector_deduplicate_entries["Woods::Storage::VectorStore::Pgvector#deduplicate_entries"]
  Woods__Storage__VectorStore__Pgvector_execute_upsert["Woods::Storage::VectorStore::Pgvector#execute_upsert"]
  Woods__Storage__VectorStore__Pgvector_conflict_violation_["Woods::Storage::VectorStore::Pgvector#conflict_violation?"]
  Woods__Storage__VectorStore__Pgvector_format_entry["Woods::Storage::VectorStore::Pgvector#format_entry"]
  Woods__Storage__VectorStore__Pgvector_build_vector_literal["Woods::Storage::VectorStore::Pgvector#build_vector_literal"]
  Float["Float"]
  Woods__Storage__VectorStore__Pgvector_build_vector_literal -->|method_call| Float
  Woods__Storage__VectorStore__Pgvector_row_to_result["Woods::Storage::VectorStore::Pgvector#row_to_result"]
  Woods__Storage__VectorStore__Pgvector_row_to_result -->|method_call| JSON
  SearchResult["SearchResult"]
  Woods__Storage__VectorStore__Pgvector_row_to_result -->|method_call| SearchResult
  Woods__Storage__VectorStore__Pgvector_build_where["Woods::Storage::VectorStore::Pgvector#build_where"]
  Woods__Storage__VectorStore__Pgvector_validate_vector_["Woods::Storage::VectorStore::Pgvector#validate_vector!"]
  Woods__Storage__VectorStore__Pgvector_validate_dimensions_["Woods::Storage::VectorStore::Pgvector#validate_dimensions!"]
  Woods__Storage__VectorStore__Qdrant["Woods::Storage::VectorStore::Qdrant"]
  Woods__Storage__VectorStore__Qdrant -->|include| Interface
  Woods__Storage__VectorStore__Qdrant__RequestError["Woods::Storage::VectorStore::Qdrant::RequestError"]
  Woods__Storage__VectorStore__Qdrant__RequestError -->|inheritance| Woods__Error
  Woods__Storage__VectorStore__Qdrant__RequestError_initialize["Woods::Storage::VectorStore::Qdrant::RequestError#initialize"]
  Woods__Storage__VectorStore__Qdrant__RequestError_retryable_["Woods::Storage::VectorStore::Qdrant::RequestError#retryable?"]
  Woods__Storage__VectorStore__Qdrant__RequestError_ambiguous_["Woods::Storage::VectorStore::Qdrant::RequestError#ambiguous?"]
  Woods__Storage__VectorStore__Qdrant_initialize["Woods::Storage::VectorStore::Qdrant#initialize"]
  Woods__Storage__VectorStore__Qdrant_validate_url_["Woods::Storage::VectorStore::Qdrant.validate_url!"]
  Woods__Storage__VectorStore__Qdrant_validate_scheme_["Woods::Storage::VectorStore::Qdrant.validate_scheme!"]
  ALLOWED_SCHEMES["ALLOWED_SCHEMES"]
  Woods__Storage__VectorStore__Qdrant_validate_scheme_ -->|method_call| ALLOWED_SCHEMES
  Woods__Storage__VectorStore__Qdrant_validate_host_present_["Woods::Storage::VectorStore::Qdrant.validate_host_present!"]
  Woods__Storage__VectorStore__Qdrant_validate_host_visibility_["Woods::Storage::VectorStore::Qdrant.validate_host_visibility!"]
  Woods__Storage__VectorStore__Qdrant_validate_host_visibility_ -->|method_call| Util__HostGuard
  Woods__Storage__VectorStore__Qdrant_private_host_["Woods::Storage::VectorStore::Qdrant.private_host?"]
  PRIVATE_HOSTNAMES["PRIVATE_HOSTNAMES"]
  Woods__Storage__VectorStore__Qdrant_private_host_ -->|method_call| PRIVATE_HOSTNAMES
  PRIVATE_IP_RANGES["PRIVATE_IP_RANGES"]
  Woods__Storage__VectorStore__Qdrant_private_host_ -->|method_call| PRIVATE_IP_RANGES
  Woods__Storage__VectorStore__Qdrant_unmap_ipv4["Woods::Storage::VectorStore::Qdrant.unmap_ipv4"]
  IPAddr["IPAddr"]
  Woods__Storage__VectorStore__Qdrant_unmap_ipv4 -->|method_call| IPAddr
  Woods__Storage__VectorStore__Qdrant_ensure_collection_["Woods::Storage::VectorStore::Qdrant#ensure_collection!"]
  Woods__Storage__VectorStore__Qdrant_point_id["Woods::Storage::VectorStore::Qdrant.point_id"]
  Util__UUID5["Util::UUID5"]
  Woods__Storage__VectorStore__Qdrant_point_id -->|method_call| Util__UUID5
  Woods__Storage__VectorStore__Qdrant_store["Woods::Storage::VectorStore::Qdrant#store"]
  Woods__Storage__VectorStore__Qdrant_store_batch["Woods::Storage::VectorStore::Qdrant#store_batch"]
  Woods__Storage__VectorStore__Qdrant_search["Woods::Storage::VectorStore::Qdrant#search"]
  Woods__Storage__VectorStore__Qdrant_search -->|method_call| SearchResult
  Woods__Storage__VectorStore__Qdrant_stored_dimensions["Woods::Storage::VectorStore::Qdrant#stored_dimensions"]
  Woods__Storage__VectorStore__Qdrant_each_id["Woods::Storage::VectorStore::Qdrant#each_id"]
  Woods__Storage__VectorStore__Qdrant_delete["Woods::Storage::VectorStore::Qdrant#delete"]
  Woods__Storage__VectorStore__Qdrant_delete_by_filter["Woods::Storage::VectorStore::Qdrant#delete_by_filter"]
  Woods__Storage__VectorStore__Qdrant_count["Woods::Storage::VectorStore::Qdrant#count"]
  Woods__Storage__VectorStore__Qdrant_normalize_dimensions["Woods::Storage::VectorStore::Qdrant#normalize_dimensions"]
  Woods__Storage__VectorStore__Qdrant_normalize_distance["Woods::Storage::VectorStore::Qdrant#normalize_distance"]
  DISTANCES["DISTANCES"]
  Woods__Storage__VectorStore__Qdrant_normalize_distance -->|method_call| DISTANCES
  Woods__Storage__VectorStore__Qdrant_validate_configured_dimensions_["Woods::Storage::VectorStore::Qdrant#validate_configured_dimensions!"]
  Integer["Integer"]
  Woods__Storage__VectorStore__Qdrant_validate_configured_dimensions_ -->|method_call| Integer
  Woods__Storage__VectorStore__Qdrant_verify_collection_dimensions_["Woods::Storage::VectorStore::Qdrant#verify_collection_dimensions!"]
  Woods__Storage__VectorStore__Qdrant_create_collection_["Woods::Storage::VectorStore::Qdrant#create_collection!"]
  Woods__Storage__VectorStore__Qdrant_extract_dimensions["Woods::Storage::VectorStore::Qdrant#extract_dimensions"]
  Woods__Storage__VectorStore__Qdrant_scroll_page["Woods::Storage::VectorStore::Qdrant#scroll_page"]
  Woods__Storage__VectorStore__Qdrant_identifier_for["Woods::Storage::VectorStore::Qdrant#identifier_for"]
  Woods__Storage__VectorStore__Qdrant_build_point["Woods::Storage::VectorStore::Qdrant#build_point"]
  Woods__Storage__VectorStore__Qdrant_truncate_response_body["Woods::Storage::VectorStore::Qdrant#truncate_response_body"]
  Woods__Storage__VectorStore__Qdrant_validate_dimensions_["Woods::Storage::VectorStore::Qdrant#validate_dimensions!"]
  Woods__Storage__VectorStore__Qdrant_build_filter["Woods::Storage::VectorStore::Qdrant#build_filter"]
  Woods__Storage__VectorStore__Qdrant_request["Woods::Storage::VectorStore::Qdrant#request"]
  Woods__Storage__VectorStore__Qdrant_parse_response["Woods::Storage::VectorStore::Qdrant#parse_response"]
  Woods__Storage__VectorStore__Qdrant_parse_response -->|method_call| JSON
  Woods__Storage__VectorStore__Qdrant_response_error["Woods::Storage::VectorStore::Qdrant#response_error"]
  Woods__Storage__VectorStore__Qdrant_response_error -->|method_call| RequestError
  Woods__Storage__VectorStore__Qdrant_transport_error["Woods::Storage::VectorStore::Qdrant#transport_error"]
  Woods__Storage__VectorStore__Qdrant_transport_error -->|method_call| RequestError
  Woods__Storage__VectorStore__Qdrant_write_request_["Woods::Storage::VectorStore::Qdrant#write_request?"]
  Woods__Storage__VectorStore__Qdrant_read_only_post_["Woods::Storage::VectorStore::Qdrant#read_only_post?"]
  Woods__Storage__VectorStore__Qdrant_http_client["Woods::Storage::VectorStore::Qdrant#http_client"]
  Woods__Storage__VectorStore__Qdrant_http_client -->|method_call| Net__HTTP
  Woods__Storage__VectorStore__Qdrant_build_request["Woods::Storage::VectorStore::Qdrant#build_request"]
  Woods__Storage__Snapshotter["Woods::Storage::Snapshotter"]
  Woods__Storage__Snapshotter__Metadata_load_or_empty["Woods::Storage::Snapshotter::Metadata.load_or_empty"]
  MetadataStore__InMemory["MetadataStore::InMemory"]
  Woods__Storage__Snapshotter__Metadata_load_or_empty -->|method_call| MetadataStore__InMemory
  Woods__Storage__Snapshotter__Metadata_load_or_empty -->|method_call| File
  MessagePack__Unpacker["MessagePack::Unpacker"]
  Woods__Storage__Snapshotter__Metadata_load_or_empty -->|method_call| MessagePack__Unpacker
  Woods__Storage__Snapshotter__Metadata_dump["Woods::Storage::Snapshotter::Metadata.dump"]
  Woods__Storage__Snapshotter__Metadata_dump -->|method_call| Pathname_new
  Woods__Storage__Snapshotter__Metadata_dump -->|method_call| Pathname
  Woods__Storage__Snapshotter__Vector_load_or_empty["Woods::Storage::Snapshotter::Vector.load_or_empty"]
  VectorStore__InMemory["VectorStore::InMemory"]
  Woods__Storage__Snapshotter__Vector_load_or_empty -->|method_call| VectorStore__InMemory
  Woods__Storage__Snapshotter__Vector_dump["Woods::Storage::Snapshotter::Vector.dump"]
  Woods__Storage__VectorStore__Interface["Woods::Storage::VectorStore::Interface"]
  Woods__Storage__VectorStore__InMemory["Woods::Storage::VectorStore::InMemory"]
  Woods__Storage__VectorStore__InMemory -->|include| Interface
  Woods__Storage__VectorStore__Interface_store["Woods::Storage::VectorStore::Interface#store"]
  Woods__Storage__VectorStore__Interface_store_batch["Woods::Storage::VectorStore::Interface#store_batch"]
  Woods__Storage__VectorStore__Interface_each_entry["Woods::Storage::VectorStore::Interface#each_entry"]
  Woods__Storage__VectorStore__Interface_each_id["Woods::Storage::VectorStore::Interface#each_id"]
  Woods__Storage__VectorStore__Interface_bulk_load["Woods::Storage::VectorStore::Interface#bulk_load"]
  Woods__Storage__VectorStore__Interface_search["Woods::Storage::VectorStore::Interface#search"]
  Woods__Storage__VectorStore__Interface_delete["Woods::Storage::VectorStore::Interface#delete"]
  Woods__Storage__VectorStore__Interface_delete_by_filter["Woods::Storage::VectorStore::Interface#delete_by_filter"]
  Woods__Storage__VectorStore__Interface_count["Woods::Storage::VectorStore::Interface#count"]
  Woods__Storage__VectorStore__InMemory_initialize["Woods::Storage::VectorStore::InMemory#initialize"]
  Woods__Storage__VectorStore__InMemory_initialize -->|method_call| Set
  Woods__Storage__VectorStore__InMemory_store["Woods::Storage::VectorStore::InMemory#store"]
  Woods__Storage__VectorStore__InMemory_bulk_load["Woods::Storage::VectorStore::InMemory#bulk_load"]
  Woods__Storage__VectorStore__InMemory_clear_["Woods::Storage::VectorStore::InMemory#clear!"]
  Woods__Storage__VectorStore__InMemory_clear_ -->|method_call| Set
  Woods__Storage__VectorStore__InMemory_each_entry["Woods::Storage::VectorStore::InMemory#each_entry"]
  Woods__Storage__VectorStore__InMemory_each_id["Woods::Storage::VectorStore::InMemory#each_id"]
  Woods__Storage__VectorStore__InMemory_search["Woods::Storage::VectorStore::InMemory#search"]
  Woods__Storage__VectorStore__InMemory_delete["Woods::Storage::VectorStore::InMemory#delete"]
  Woods__Storage__VectorStore__InMemory_delete_by_filter["Woods::Storage::VectorStore::InMemory#delete_by_filter"]
  Woods__Storage__VectorStore__InMemory_count["Woods::Storage::VectorStore::InMemory#count"]
  Woods__Storage__VectorStore__InMemory_filter_match_["Woods::Storage::VectorStore::InMemory#filter_match?"]
  Woods__Storage__VectorStore__InMemory_metadata_value["Woods::Storage::VectorStore::InMemory#metadata_value"]
  Woods__Storage__VectorStore__InMemory_append["Woods::Storage::VectorStore::InMemory#append"]
  Woods__Storage__VectorStore__InMemory_overwrite["Woods::Storage::VectorStore::InMemory#overwrite"]
  Woods__Storage__VectorStore__InMemory_gather_candidates["Woods::Storage::VectorStore::InMemory#gather_candidates"]
  Woods__Storage__VectorStore__InMemory_cosine_similarity_strided["Woods::Storage::VectorStore::InMemory#cosine_similarity_strided"]
  Woods__Tasks["Woods::Tasks"]
  Woods__Tasks_build_embed_indexer["Woods::Tasks#build_embed_indexer"]
  Woods__Tasks_build_embed_indexer -->|method_call| Woods
  Builder["Builder"]
  Woods__Tasks_build_embed_indexer -->|method_call| Builder
  Embedding__Indexer["Embedding::Indexer"]
  Woods__Tasks_build_embed_indexer -->|method_call| Embedding__Indexer
  Woods__Tasks_verify_store_dimensions_["Woods::Tasks#verify_store_dimensions!"]
  Woods__Tasks_build_resolved_config["Woods::Tasks#build_resolved_config"]
  Woods__Tasks_build_resolved_config -->|method_call| ResolvedConfig
  Woods__Tasks_print_embed_stats["Woods::Tasks#print_embed_stats"]
  Woods__Temporal["Woods::Temporal"]
  Woods__Temporal__JsonSnapshotStore_initialize["Woods::Temporal::JsonSnapshotStore#initialize"]
  Woods__Temporal__JsonSnapshotStore_initialize -->|method_call| File
  Woods__Temporal__JsonSnapshotStore_initialize -->|method_call| FileUtils
  Woods__Temporal__JsonSnapshotStore_capture["Woods::Temporal::JsonSnapshotStore#capture"]
  Woods__Temporal__JsonSnapshotStore_list["Woods::Temporal::JsonSnapshotStore#list"]
  Woods__Temporal__JsonSnapshotStore_find["Woods::Temporal::JsonSnapshotStore#find"]
  Woods__Temporal__JsonSnapshotStore_find -->|method_call| File
  Woods__Temporal__JsonSnapshotStore_find -->|method_call| JSON
  Woods__Temporal__JsonSnapshotStore_diff["Woods::Temporal::JsonSnapshotStore#diff"]
  Woods__Temporal__JsonSnapshotStore_unit_history["Woods::Temporal::JsonSnapshotStore#unit_history"]
  Woods__Temporal__JsonSnapshotStore_mget["Woods::Temporal::JsonSnapshotStore#mget"]
  Woods__Temporal__JsonSnapshotStore_build_snapshot["Woods::Temporal::JsonSnapshotStore#build_snapshot"]
  Woods__Temporal__JsonSnapshotStore_index_units["Woods::Temporal::JsonSnapshotStore#index_units"]
  Woods__Temporal__JsonSnapshotStore_compute_diff["Woods::Temporal::JsonSnapshotStore#compute_diff"]
  Woods__Temporal__JsonSnapshotStore_mark_changed_entries["Woods::Temporal::JsonSnapshotStore#mark_changed_entries"]
  Woods__Temporal__JsonSnapshotStore_snapshot_path["Woods::Temporal::JsonSnapshotStore#snapshot_path"]
  Woods__Temporal__JsonSnapshotStore_snapshot_path -->|method_call| File
  Woods__Temporal__JsonSnapshotStore_write_snapshot["Woods::Temporal::JsonSnapshotStore#write_snapshot"]
  Woods__Temporal__JsonSnapshotStore_write_snapshot -->|method_call| AtomicFile
  Woods__Temporal__JsonSnapshotStore_load_snapshot_with_units["Woods::Temporal::JsonSnapshotStore#load_snapshot_with_units"]
  Woods__Temporal__JsonSnapshotStore_load_snapshot_with_units -->|method_call| File
  Woods__Temporal__JsonSnapshotStore_load_all_summaries["Woods::Temporal::JsonSnapshotStore#load_all_summaries"]
  Woods__Temporal__JsonSnapshotStore_load_all_summaries -->|method_call| Dir_glob
  Woods__Temporal__JsonSnapshotStore_load_all_summaries -->|method_call| JSON
  Woods__Temporal__JsonSnapshotStore_load_all_with_units["Woods::Temporal::JsonSnapshotStore#load_all_with_units"]
  Woods__Temporal__JsonSnapshotStore_load_all_with_units -->|method_call| Dir_glob
  Woods__Temporal__JsonSnapshotStore_find_latest["Woods::Temporal::JsonSnapshotStore#find_latest"]
  Woods__Temporal__JsonSnapshotStore_symbolize_snapshot["Woods::Temporal::JsonSnapshotStore#symbolize_snapshot"]
  Woods__Temporal__JsonSnapshotStore_symbolize_units["Woods::Temporal::JsonSnapshotStore#symbolize_units"]
  Woods__Temporal__SnapshotStore_initialize["Woods::Temporal::SnapshotStore#initialize"]
  Woods__Temporal__SnapshotStore_validate_schema_["Woods::Temporal::SnapshotStore#validate_schema!"]
  REQUIRED_TABLES["REQUIRED_TABLES"]
  Woods__Temporal__SnapshotStore_validate_schema_ -->|method_call| REQUIRED_TABLES
  Woods__Temporal__SnapshotStore_probe_table_["Woods::Temporal::SnapshotStore#probe_table!"]
  Woods__Temporal__SnapshotStore_schema_error_message["Woods::Temporal::SnapshotStore#schema_error_message"]
  Woods__Temporal__SnapshotStore_capture["Woods::Temporal::SnapshotStore#capture"]
  Woods__Temporal__SnapshotStore_list["Woods::Temporal::SnapshotStore#list"]
  Woods__Temporal__SnapshotStore_find["Woods::Temporal::SnapshotStore#find"]
  Woods__Temporal__SnapshotStore_diff["Woods::Temporal::SnapshotStore#diff"]
  Woods__Temporal__SnapshotStore_unit_history["Woods::Temporal::SnapshotStore#unit_history"]
  Woods__Temporal__SnapshotStore_history_entry_from_row["Woods::Temporal::SnapshotStore#history_entry_from_row"]
  Woods__Temporal__SnapshotStore_mark_changed_entries["Woods::Temporal::SnapshotStore#mark_changed_entries"]
  Woods__Temporal__SnapshotStore_mget["Woods::Temporal::SnapshotStore#mget"]
  Woods__Temporal__SnapshotStore_upsert_snapshot["Woods::Temporal::SnapshotStore#upsert_snapshot"]
  Woods__Temporal__SnapshotStore_upsert_snapshot -->|method_call| Time_now
  Woods__Temporal__SnapshotStore_upsert_snapshot -->|method_call| Time
  Woods__Temporal__SnapshotStore_upsert_snapshot -->|method_call| JSON
  Woods__Temporal__SnapshotStore_prune_orphaned_units["Woods::Temporal::SnapshotStore#prune_orphaned_units"]
  Woods__Temporal__SnapshotStore_update_diff_stats["Woods::Temporal::SnapshotStore#update_diff_stats"]
  Woods__Temporal__SnapshotStore_find_latest["Woods::Temporal::SnapshotStore#find_latest"]
  Woods__Temporal__SnapshotStore_fetch_snapshot_id["Woods::Temporal::SnapshotStore#fetch_snapshot_id"]
  Woods__Temporal__SnapshotStore_insert_unit_hashes["Woods::Temporal::SnapshotStore#insert_unit_hashes"]
  Woods__Temporal__SnapshotStore_load_snapshot_units["Woods::Temporal::SnapshotStore#load_snapshot_units"]
  Woods__Temporal__SnapshotStore_compute_diff["Woods::Temporal::SnapshotStore#compute_diff"]
  Woods__Temporal__SnapshotStore_compute_diff_stats["Woods::Temporal::SnapshotStore#compute_diff_stats"]
  Woods__Temporal__SnapshotStore_row_to_hash["Woods::Temporal::SnapshotStore#row_to_hash"]
  Woods__TokenUtils["Woods::TokenUtils"]
  Woods__TokenUtils_chars_per_token_for["Woods::TokenUtils#chars_per_token_for"]
  CHARS_PER_TOKEN_BY_PROVIDER["CHARS_PER_TOKEN_BY_PROVIDER"]
  Woods__TokenUtils_chars_per_token_for -->|method_call| CHARS_PER_TOKEN_BY_PROVIDER
  Woods__TokenUtils_estimate_tokens["Woods::TokenUtils#estimate_tokens"]
  Woods__TokenUtils_estimate_tokens_for["Woods::TokenUtils#estimate_tokens_for"]
  Woods__Unblocked["Woods::Unblocked"]
  Woods__Unblocked__ApiError["Woods::Unblocked::ApiError"]
  Woods__Unblocked__ApiError -->|inheritance| Woods__Error
  Woods__Unblocked__Client["Woods::Unblocked::Client"]
  Woods__Unblocked__ApiError_initialize["Woods::Unblocked::ApiError#initialize"]
  Woods__Unblocked__Client_initialize["Woods::Unblocked::Client#initialize"]
  Woods__Unblocked__Client_put_document["Woods::Unblocked::Client#put_document"]
  Woods__Unblocked__Client_create_collection["Woods::Unblocked::Client#create_collection"]
  Woods__Unblocked__Client_delete_document["Woods::Unblocked::Client#delete_document"]
  Woods__Unblocked__Client_list_documents["Woods::Unblocked::Client#list_documents"]
  Woods__Unblocked__Client_all_documents["Woods::Unblocked::Client#all_documents"]
  Woods__Unblocked__Client_request["Woods::Unblocked::Client#request"]
  Woods__Unblocked__Client_request -->|method_call| RETRYABLE_STATUS_CODES
  Woods__Unblocked__Client_request -->|method_call| Woods__RetryAfter
  Woods__Unblocked__Client_execute_http["Woods::Unblocked::Client#execute_http"]
  Woods__Unblocked__Client_execute_http -->|method_call| Net__HTTP
  Woods__Unblocked__Client_safe_to_retry_["Woods::Unblocked::Client#safe_to_retry?"]
  Woods__Unblocked__Client_safe_to_retry_ -->|method_call| IDEMPOTENT_METHODS
  Woods__Unblocked__Client_safe_to_retry_ -->|method_call| PRE_REQUEST_ERRORS
  Woods__Unblocked__Client_raise_ambiguous_network_error["Woods::Unblocked::Client#raise_ambiguous_network_error"]
  Woods__Unblocked__Client_raise_ambiguous_response_error["Woods::Unblocked::Client#raise_ambiguous_response_error"]
  Woods__Unblocked__Client_raise_ambiguous_response_error -->|method_call| JSON
  Woods__Unblocked__Client_redact_token["Woods::Unblocked::Client#redact_token"]
  Woods__Unblocked__Client_build_request["Woods::Unblocked::Client#build_request"]
  Net__HTTP__Put["Net::HTTP::Put"]
  Woods__Unblocked__Client_build_request -->|method_call| Net__HTTP__Put
  Woods__Unblocked__Client_build_request -->|method_call| Net__HTTP__Post
  Woods__Unblocked__Client_build_request -->|method_call| Net__HTTP__Get
  Net__HTTP__Delete["Net::HTTP::Delete"]
  Woods__Unblocked__Client_build_request -->|method_call| Net__HTTP__Delete
  Woods__Unblocked__Client_parse_response["Woods::Unblocked::Client#parse_response"]
  Woods__Unblocked__Client_parse_response -->|method_call| JSON
  Woods__Unblocked__Client_raise_api_error["Woods::Unblocked::Client#raise_api_error"]
  Woods__Unblocked__Client_raise_api_error -->|method_call| JSON
  Woods__Unblocked__DocumentBuilder["Woods::Unblocked::DocumentBuilder"]
  Woods__Unblocked__DocumentBuilder_initialize["Woods::Unblocked::DocumentBuilder#initialize"]
  Woods__Unblocked__DocumentBuilder_build["Woods::Unblocked::DocumentBuilder#build"]
  Woods__Unblocked__DocumentBuilder_uri_for["Woods::Unblocked::DocumentBuilder#uri_for"]
  Woods__Unblocked__DocumentBuilder_normalize_ref["Woods::Unblocked::DocumentBuilder#normalize_ref"]
  UNRESOLVED_REFS["UNRESOLVED_REFS"]
  Woods__Unblocked__DocumentBuilder_normalize_ref -->|method_call| UNRESOLVED_REFS
  Woods__Unblocked__DocumentBuilder_encode_path["Woods::Unblocked::DocumentBuilder#encode_path"]
  ERB__Util["ERB::Util"]
  Woods__Unblocked__DocumentBuilder_encode_path -->|method_call| ERB__Util
  Woods__Unblocked__DocumentBuilder_build_body["Woods::Unblocked::DocumentBuilder#build_body"]
  Woods__Unblocked__DocumentBuilder_redact_credentials["Woods::Unblocked::DocumentBuilder#redact_credentials"]
  Woods__Unblocked__DocumentBuilder_credential_scanner["Woods::Unblocked::DocumentBuilder#credential_scanner"]
  Woods__Unblocked__DocumentBuilder_credential_scanner -->|method_call| Woods__Console__CredentialScanner
  Woods__Unblocked__DocumentBuilder_build_model_body["Woods::Unblocked::DocumentBuilder#build_model_body"]
  Woods__Unblocked__DocumentBuilder_model_header["Woods::Unblocked::DocumentBuilder#model_header"]
  Woods__Unblocked__DocumentBuilder_model_associations["Woods::Unblocked::DocumentBuilder#model_associations"]
  Woods__Unblocked__DocumentBuilder_model_associations -->|method_call| Woods__Export__UnitFacts
  Woods__Unblocked__DocumentBuilder_model_dependents["Woods::Unblocked::DocumentBuilder#model_dependents"]
  Woods__Unblocked__DocumentBuilder_model_entry_points["Woods::Unblocked::DocumentBuilder#model_entry_points"]
  Woods__Unblocked__DocumentBuilder_model_schema_highlights["Woods::Unblocked::DocumentBuilder#model_schema_highlights"]
  Woods__Unblocked__DocumentBuilder_model_schema_highlights -->|method_call| Woods__Export__UnitFacts_new
  Woods__Unblocked__DocumentBuilder_model_schema_highlights -->|method_call| Woods__Export__UnitFacts
  Woods__Unblocked__DocumentBuilder_model_side_effects["Woods::Unblocked::DocumentBuilder#model_side_effects"]
  Woods__Unblocked__DocumentBuilder_build_controller_body["Woods::Unblocked::DocumentBuilder#build_controller_body"]
  Woods__Unblocked__DocumentBuilder_controller_routes["Woods::Unblocked::DocumentBuilder#controller_routes"]
  Woods__Unblocked__DocumentBuilder_controller_dependencies["Woods::Unblocked::DocumentBuilder#controller_dependencies"]
  Woods__Unblocked__DocumentBuilder_controller_dependents["Woods::Unblocked::DocumentBuilder#controller_dependents"]
  Woods__Unblocked__DocumentBuilder_build_graphql_body["Woods::Unblocked::DocumentBuilder#build_graphql_body"]
  Woods__Unblocked__DocumentBuilder_build_generic_body["Woods::Unblocked::DocumentBuilder#build_generic_body"]
  Woods__Unblocked__DocumentBuilder_format_enum_values["Woods::Unblocked::DocumentBuilder#format_enum_values"]
  Woods__Unblocked__DocumentBuilder_format_callbacks["Woods::Unblocked::DocumentBuilder#format_callbacks"]
  Woods__Unblocked__Exporter["Woods::Unblocked::Exporter"]
  Woods__Unblocked__Exporter_initialize["Woods::Unblocked::Exporter#initialize"]
  Woods__Unblocked__Exporter_initialize -->|method_call| ENV_fetch
  Woods__Unblocked__Exporter_initialize -->|method_call| ENV
  RateLimiter["RateLimiter"]
  Woods__Unblocked__Exporter_initialize -->|method_call| RateLimiter
  Woods__Unblocked__Exporter_initialize -->|method_call| Client
  DocumentBuilder["DocumentBuilder"]
  Woods__Unblocked__Exporter_initialize -->|method_call| DocumentBuilder
  Woods__Unblocked__Exporter_initialize -->|method_call| Set
  Woods__Unblocked__Exporter_sync_all["Woods::Unblocked::Exporter#sync_all"]
  Woods__Unblocked__Exporter_sync_all -->|method_call| Set
  FULL_SYNC_TYPES["FULL_SYNC_TYPES"]
  Woods__Unblocked__Exporter_sync_all -->|method_call| FULL_SYNC_TYPES
  PARTIAL_SYNC_TYPES["PARTIAL_SYNC_TYPES"]
  Woods__Unblocked__Exporter_sync_all -->|method_call| PARTIAL_SYNC_TYPES
  Woods__Unblocked__Exporter_sync_type["Woods::Unblocked::Exporter#sync_type"]
  Woods__Unblocked__Exporter_sync_type_partial["Woods::Unblocked::Exporter#sync_type_partial"]
  Woods__Unblocked__Exporter_sync_units["Woods::Unblocked::Exporter#sync_units"]
  Woods__Unblocked__Exporter_sync_unit_data["Woods::Unblocked::Exporter#sync_unit_data"]
  Woods__Unblocked__Exporter_push_document["Woods::Unblocked::Exporter#push_document"]
  Woods__Unblocked__Exporter_purge_stale["Woods::Unblocked::Exporter#purge_stale"]
  Woods__Unblocked__Exporter_resolve_missing_document_ids["Woods::Unblocked::Exporter#resolve_missing_document_ids"]
  Woods__Unblocked__Exporter_guard_blocks_purge_["Woods::Unblocked::Exporter#guard_blocks_purge?"]
  Woods__Unblocked__Exporter_reconcile_from_remote["Woods::Unblocked::Exporter#reconcile_from_remote"]
  Woods__Unblocked__Exporter_track_uri["Woods::Unblocked::Exporter#track_uri"]
  Woods__Unblocked__Exporter_effective_uri["Woods::Unblocked::Exporter#effective_uri"]
  Woods__Unblocked__Exporter_build_uri_index["Woods::Unblocked::Exporter#build_uri_index"]
  Woods__Unblocked__Exporter_build_uri_index -->|method_call| Hash
  Woods__Unblocked__Exporter_synced_types["Woods::Unblocked::Exporter#synced_types"]
  Woods__Unblocked__Exporter_synced_types -->|method_call| FULL_SYNC_TYPES
  Woods__Unblocked__Exporter_fingerprint["Woods::Unblocked::Exporter#fingerprint"]
  Woods__Unblocked__Exporter_fingerprint -->|method_call| Digest__SHA256
  Woods__Unblocked__Exporter_note_budget_exhaustion["Woods::Unblocked::Exporter#note_budget_exhaustion"]
  Woods__Unblocked__Exporter_build_reader["Woods::Unblocked::Exporter#build_reader"]
  Woods__Unblocked__Exporter_build_reader -->|method_call| Woods__MCP__IndexReader
  Woods__Unblocked__Exporter_extracted_ref["Woods::Unblocked::Exporter#extracted_ref"]
  Woods__Unblocked__Exporter_save_manifest["Woods::Unblocked::Exporter#save_manifest"]
  Woods__Unblocked__Exporter_build_manifest["Woods::Unblocked::Exporter#build_manifest"]
  Woods__Unblocked__Exporter_build_manifest -->|method_call| SyncManifest
  Woods__Unblocked__Exporter_empty_stats["Woods::Unblocked::Exporter#empty_stats"]
  Woods__Unblocked__Exporter_cap_errors["Woods::Unblocked::Exporter#cap_errors"]
  Woods__Unblocked__Exporter_log["Woods::Unblocked::Exporter#log"]
  Woods__Unblocked__BudgetExhaustedError["Woods::Unblocked::BudgetExhaustedError"]
  Woods__Unblocked__BudgetExhaustedError -->|inheritance| Woods__Error
  Woods__Unblocked__RateLimiter["Woods::Unblocked::RateLimiter"]
  Woods__Unblocked__RateLimiter_initialize["Woods::Unblocked::RateLimiter#initialize"]
  Woods__Unblocked__RateLimiter_initialize -->|method_call| Mutex
  Woods__Unblocked__RateLimiter_track["Woods::Unblocked::RateLimiter#track"]
  Woods__Unblocked__RateLimiter_remaining["Woods::Unblocked::RateLimiter#remaining"]
  Woods__Unblocked__RateLimiter_used["Woods::Unblocked::RateLimiter#used"]
  Woods__Unblocked__RateLimiter_reset_["Woods::Unblocked::RateLimiter#reset!"]
  Woods__Unblocked__RateLimiter_warn_if_approaching_limit["Woods::Unblocked::RateLimiter#warn_if_approaching_limit"]
  Woods__Unblocked__SyncManifest["Woods::Unblocked::SyncManifest"]
  Woods__Unblocked__SyncManifest_initialize["Woods::Unblocked::SyncManifest#initialize"]
  Woods__Unblocked__SyncManifest_empty_["Woods::Unblocked::SyncManifest#empty?"]
  Woods__Unblocked__SyncManifest_unchanged_["Woods::Unblocked::SyncManifest#unchanged?"]
  Woods__Unblocked__SyncManifest_record["Woods::Unblocked::SyncManifest#record"]
  Woods__Unblocked__SyncManifest_document_id_for["Woods::Unblocked::SyncManifest#document_id_for"]
  Woods__Unblocked__SyncManifest_stale_uris["Woods::Unblocked::SyncManifest#stale_uris"]
  Woods__Unblocked__SyncManifest_size["Woods::Unblocked::SyncManifest#size"]
  Woods__Unblocked__SyncManifest_forget["Woods::Unblocked::SyncManifest#forget"]
  Woods__Unblocked__SyncManifest_save["Woods::Unblocked::SyncManifest#save"]
  Woods__Unblocked__SyncManifest_save -->|method_call| JSON
  Woods__Unblocked__SyncManifest_save -->|method_call| AtomicFile
  Woods__Unblocked__SyncManifest_load["Woods::Unblocked::SyncManifest#load"]
  Woods__Unblocked__SyncManifest_load -->|method_call| File
  Woods__Unblocked__SyncManifest_load -->|method_call| JSON
  Woods__Unblocked__SyncManifest_discard["Woods::Unblocked::SyncManifest#discard"]
  Woods__UpdateCheck["Woods::UpdateCheck"]
  Woods__UpdateCheck_check["Woods::UpdateCheck#check"]
  Woods__UpdateCheck_status_hash["Woods::UpdateCheck#status_hash"]
  Woods__UpdateCheck_tool_not_found_message["Woods::UpdateCheck#tool_not_found_message"]
  Woods__UpdateCheck_disabled_["Woods::UpdateCheck#disabled?"]
  Woods__UpdateCheck_disabled_ -->|method_call| ENV___
  Woods__UpdateCheck_disabled_ -->|method_call| ENV
  Woods__UpdateCheck_result["Woods::UpdateCheck#result"]
  Woods__UpdateCheck_newer_["Woods::UpdateCheck#newer?"]
  Gem__Version_new["Gem::Version.new"]
  Woods__UpdateCheck_newer_ -->|method_call| Gem__Version_new
  Gem__Version["Gem::Version"]
  Woods__UpdateCheck_newer_ -->|method_call| Gem__Version
  Woods__UpdateCheck_cached_or_refreshed_latest["Woods::UpdateCheck#cached_or_refreshed_latest"]
  Woods__UpdateCheck_fresh_entry_["Woods::UpdateCheck#fresh_entry?"]
  Woods__UpdateCheck_refresh["Woods::UpdateCheck#refresh"]
  Woods__UpdateCheck_read_cache["Woods::UpdateCheck#read_cache"]
  Woods__UpdateCheck_read_cache -->|method_call| File
  Woods__UpdateCheck_read_cache -->|method_call| JSON
  Woods__UpdateCheck_write_cache["Woods::UpdateCheck#write_cache"]
  Woods__UpdateCheck_write_cache -->|method_call| Woods__AtomicFile
  Woods__UpdateCheck_default_cache_path["Woods::UpdateCheck#default_cache_path"]
  Woods__UpdateCheck_default_cache_path -->|method_call| ENV
  Woods__UpdateCheck_default_cache_path -->|method_call| File
  Woods__UpdateCheck_fetch_latest_version["Woods::UpdateCheck#fetch_latest_version"]
  Woods__UpdateCheck_fetch_latest_version -->|method_call| Net__HTTP
  Woods__UpdateCheck_fetch_latest_version -->|method_call| JSON_parse
  Woods__UpdateCheck_fetch_latest_version -->|method_call| JSON
  Woods__Util["Woods::Util"]
  Woods__Util__HostGuard["Woods::Util::HostGuard"]
  Woods__Util__HostGuard_canonicalize["Woods::Util::HostGuard#canonicalize"]
  Woods__Util__HostGuard_suspicious_numeric_host_["Woods::Util::HostGuard#suspicious_numeric_host?"]
  Woods__Util__UUID5["Woods::Util::UUID5"]
  Woods__Util__UUID5_generate["Woods::Util::UUID5.generate"]
  Digest__SHA1["Digest::SHA1"]
  Woods__Util__UUID5_generate -->|method_call| Digest__SHA1
  Woods__Util__UUID5_uuid_["Woods::Util::UUID5.uuid?"]
  UUID_PATTERN["UUID_PATTERN"]
  Woods__Util__UUID5_uuid_ -->|method_call| UUID_PATTERN
  Woods__Util__UUID5_pack_uuid["Woods::Util::UUID5.pack_uuid"]
  Woods__Util__UUID5_name_bytes["Woods::Util::UUID5.name_bytes"]
  Woods__Util__UUID5_apply_version_and_variant["Woods::Util::UUID5.apply_version_and_variant"]
  Woods__Util__UUID5_format_uuid["Woods::Util::UUID5.format_uuid"]
  GROUP_LENGTHS_map["GROUP_LENGTHS.map"]
  Woods__Util__UUID5_format_uuid -->|method_call| GROUP_LENGTHS_map
  GROUP_LENGTHS["GROUP_LENGTHS"]
  Woods__Util__UUID5_format_uuid -->|method_call| GROUP_LENGTHS
  Woods__Watch["Woods::Watch"]
  Woods__Watch__Daemon["Woods::Watch::Daemon"]
  Woods__Watch__Daemon__NullLogger["Woods::Watch::Daemon::NullLogger"]
  Woods__Watch__Daemon__RailsReloader["Woods::Watch::Daemon::RailsReloader"]
  Woods__Watch__Daemon_initialize["Woods::Watch::Daemon#initialize"]
  Woods__Watch__Daemon_initialize -->|method_call| Rails
  Woods__Watch__Daemon_initialize -->|method_call| Dir
  Woods__Watch__Daemon_initialize -->|method_call| Woods__Extractor
  RailsReloader["RailsReloader"]
  Woods__Watch__Daemon_initialize -->|method_call| RailsReloader
  Woods__Watch__Daemon_initialize -->|method_call| Generation
  Status["Status"]
  Woods__Watch__Daemon_initialize -->|method_call| Status
  Woods__Watch__Daemon_run["Woods::Watch::Daemon#run"]
  Woods__Watch__Daemon_stop["Woods::Watch::Daemon#stop"]
  Woods__Watch__Daemon_process["Woods::Watch::Daemon#process"]
  Woods__Watch__Daemon_process -->|method_call| ChangeSet
  Woods__Watch__Daemon_run_started["Woods::Watch::Daemon#run_started"]
  Woods__Watch__Daemon_shut_down["Woods::Watch::Daemon#shut_down"]
  Woods__Watch__Daemon_launch_watcher["Woods::Watch::Daemon#launch_watcher"]
  Woods__Watch__Daemon_launch_watcher -->|method_call| Thread
  Woods__Watch__Daemon_stop_heartbeat["Woods::Watch::Daemon#stop_heartbeat"]
  Woods__Watch__Daemon_required_action["Woods::Watch::Daemon#required_action"]
  Woods__Watch__Daemon_nothing_to_do["Woods::Watch::Daemon#nothing_to_do"]
  Woods__Watch__Daemon_default_lock["Woods::Watch::Daemon#default_lock"]
  Coordination__PipelineLock["Coordination::PipelineLock"]
  Woods__Watch__Daemon_default_lock -->|method_call| Coordination__PipelineLock
  Woods__Watch__Daemon_reset_cycle_state["Woods::Watch::Daemon#reset_cycle_state"]
  Woods__Watch__Daemon_reset_cycle_state -->|method_call| Set
  Woods__Watch__Daemon_reset_cycle_state -->|method_call| Mutex
  Woods__Watch__Daemon_settle["Woods::Watch::Daemon#settle"]
  Woods__Watch__Daemon_enqueue["Woods::Watch::Daemon#enqueue"]
  ChangeSet_new["ChangeSet.new"]
  Woods__Watch__Daemon_enqueue -->|method_call| ChangeSet_new
  Woods__Watch__Daemon_enqueue -->|method_call| ChangeSet
  Woods__Watch__Daemon_drain_with["Woods::Watch::Daemon#drain_with"]
  Woods__Watch__Daemon_drain_with -->|method_call| Set
  Woods__Watch__Daemon_carry_forward["Woods::Watch::Daemon#carry_forward"]
  Woods__Watch__Daemon_drain["Woods::Watch::Daemon#drain"]
  Woods__Watch__Daemon_drain_cycles["Woods::Watch::Daemon#drain_cycles"]
  Woods__Watch__Daemon_pending_empty_["Woods::Watch::Daemon#pending_empty?"]
  Woods__Watch__Daemon_persist_pending["Woods::Watch::Daemon#persist_pending"]
  Woods__Watch__Daemon_persist_pending -->|method_call| AtomicFile
  Woods__Watch__Daemon_restore_pending["Woods::Watch::Daemon#restore_pending"]
  Woods__Watch__Daemon_restore_pending -->|method_call| File
  Woods__Watch__Daemon_restore_pending -->|method_call| JSON
  Woods__Watch__Daemon_pending_path["Woods::Watch::Daemon#pending_path"]
  Woods__Watch__Daemon_pending_path -->|method_call| File
  Woods__Watch__Daemon_catch_up["Woods::Watch::Daemon#catch_up"]
  Woods__Watch__Daemon_stale_deletions_["Woods::Watch::Daemon#stale_deletions?"]
  File_exist_["File.exist?"]
  Woods__Watch__Daemon_stale_deletions_ -->|method_call| File_exist_
  Woods__Watch__Daemon_stale_deletions_ -->|method_call| File
  Woods__Watch__Daemon_persisted_registered_paths["Woods::Watch::Daemon#persisted_registered_paths"]
  Woods__Watch__Daemon_persisted_registered_paths -->|method_call| Woods__Generation_new
  Woods__Watch__Daemon_persisted_registered_paths -->|method_call| Woods__Generation
  Woods__Watch__Daemon_persisted_registered_paths -->|method_call| File
  Woods__Watch__Daemon_persisted_registered_paths -->|method_call| JSON_parse
  Woods__Watch__Daemon_persisted_registered_paths -->|method_call| JSON
  Woods__Watch__Daemon_persisted_registered_paths -->|method_call| Woods__DependencyGraph
  Woods__Watch__Daemon_reconcile_deletions["Woods::Watch::Daemon#reconcile_deletions"]
  Woods__Watch__Daemon_uncovered_paths["Woods::Watch::Daemon#uncovered_paths"]
  TreeScan_files["TreeScan.files"]
  Woods__Watch__Daemon_uncovered_paths -->|method_call| TreeScan_files
  Woods__Watch__Daemon_uncovered_["Woods::Watch::Daemon#uncovered?"]
  Woods__Watch__Daemon_uncovered_ -->|method_call| File_mtime_to_f
  Woods__Watch__Daemon_uncovered_ -->|method_call| File_mtime
  Woods__Watch__Daemon_uncovered_ -->|method_call| File
  Woods__Watch__Daemon_index_watermark["Woods::Watch::Daemon#index_watermark"]
  Woods__Watch__Daemon_index_watermark -->|method_call| File_mtime
  Woods__Watch__Daemon_index_watermark -->|method_call| File
  Woods__Watch__Daemon_start_heartbeat["Woods::Watch::Daemon#start_heartbeat"]
  Woods__Watch__Daemon_start_heartbeat -->|method_call| Thread
  Woods__Watch__Daemon_retry_pending["Woods::Watch::Daemon#retry_pending"]
  Woods__Watch__Daemon_heartbeat_tick["Woods::Watch::Daemon#heartbeat_tick"]
  Woods__Watch__Daemon_idle_expired_["Woods::Watch::Daemon#idle_expired?"]
  Woods__Watch__Daemon_restamp_status["Woods::Watch::Daemon#restamp_status"]
  Woods__Watch__Daemon_start_watching["Woods::Watch::Daemon#start_watching"]
  Watcher["Watcher"]
  Woods__Watch__Daemon_start_watching -->|method_call| Watcher
  Woods__Watch__Daemon_attempt_reload["Woods::Watch::Daemon#attempt_reload"]
  Woods__Watch__Daemon_degraded_reload["Woods::Watch::Daemon#degraded_reload"]
  Woods__Watch__Daemon_require_restart["Woods::Watch::Daemon#require_restart"]
  Woods__Watch__Daemon_extract["Woods::Watch::Daemon#extract"]
  Woods__Watch__Daemon_acquire_lock_for["Woods::Watch::Daemon#acquire_lock_for"]
  Woods__Watch__Daemon_release_lock_quietly["Woods::Watch::Daemon#release_lock_quietly"]
  Woods__Watch__Daemon_contended["Woods::Watch::Daemon#contended"]
  Woods__Watch__Daemon_run_extraction["Woods::Watch::Daemon#run_extraction"]
  Woods__Watch__Daemon_actionable_count["Woods::Watch::Daemon#actionable_count"]
  Woods__Watch__Daemon_wrote_without_publishing_["Woods::Watch::Daemon#wrote_without_publishing?"]
  Woods__Watch__Daemon_wrote_without_publishing_ -->|method_call| Array
  Woods__Watch__Daemon_unpublished["Woods::Watch::Daemon#unpublished"]
  Woods__Watch__Daemon_publish["Woods::Watch::Daemon#publish"]
  Woods__Watch__Daemon_log_storm["Woods::Watch::Daemon#log_storm"]
  Woods__Watch__Daemon_outcome["Woods::Watch::Daemon#outcome"]
  Woods__Watch__Daemon_publish_status["Woods::Watch::Daemon#publish_status"]
  Woods__Watch__Daemon_another_daemon_alive_["Woods::Watch::Daemon#another_daemon_alive?"]
  Woods__Watch__Daemon_another_daemon_alive_ -->|method_call| ENV___
  Woods__Watch__Daemon_another_daemon_alive_ -->|method_call| ENV
  Woods__Watch__Daemon_claim_startup_["Woods::Watch::Daemon#claim_startup?"]
  Woods__Watch__Daemon_claim_startup_ -->|method_call| ENV___
  Woods__Watch__Daemon_claim_startup_ -->|method_call| ENV
  Woods__Watch__Daemon_create_claim["Woods::Watch::Daemon#create_claim"]
  Woods__Watch__Daemon_create_claim -->|method_call| FileUtils
  Woods__Watch__Daemon_create_claim -->|method_call| JSON
  Woods__Watch__Daemon_create_claim -->|method_call| File
  Woods__Watch__Daemon_reclaim_if_stale["Woods::Watch::Daemon#reclaim_if_stale"]
  Woods__Watch__Daemon_reclaim_if_stale -->|method_call| FileUtils
  Woods__Watch__Daemon_claim_inode["Woods::Watch::Daemon#claim_inode"]
  File_stat["File.stat"]
  Woods__Watch__Daemon_claim_inode -->|method_call| File_stat
  Woods__Watch__Daemon_claim_inode -->|method_call| File
  Woods__Watch__Daemon_stale_claim_["Woods::Watch::Daemon#stale_claim?"]
  Woods__Watch__Daemon_stale_claim_ -->|method_call| JSON
  Woods__Watch__Daemon_same_claim_host_["Woods::Watch::Daemon#same_claim_host?"]
  Woods__Watch__Daemon_claim_pid_alive_["Woods::Watch::Daemon#claim_pid_alive?"]
  Woods__Watch__Daemon_claim_pid_alive_ -->|method_call| Process
  Woods__Watch__Daemon_release_claim["Woods::Watch::Daemon#release_claim"]
  Woods__Watch__Daemon_release_claim -->|method_call| FileUtils
  Woods__Watch__Daemon_claim_path["Woods::Watch::Daemon#claim_path"]
  Woods__Watch__Daemon_claim_path -->|method_call| File
  Woods__Watch__Daemon_build_watcher["Woods::Watch::Daemon#build_watcher"]
  Woods__Watch__Daemon_build_watcher -->|method_call| Watcher
  Woods__Watch__Daemon_ignored_directories["Woods::Watch::Daemon#ignored_directories"]
  Woods__Watch__Daemon_output_dir_within_root["Woods::Watch::Daemon#output_dir_within_root"]
  Woods__Watch__Daemon_resolve_path["Woods::Watch::Daemon#resolve_path"]
  Woods__Watch__Daemon_resolve_path -->|method_call| File
  Woods__Watch__Daemon_monotonic_now["Woods::Watch::Daemon#monotonic_now"]
  Woods__Watch__Daemon_monotonic_now -->|method_call| Process
  Woods__Watch__Daemon_elapsed_ms["Woods::Watch::Daemon#elapsed_ms"]
  Woods__Watch__Daemon_default_logger["Woods::Watch::Daemon#default_logger"]
  Woods__Watch__Daemon_default_logger -->|method_call| Rails
  NullLogger["NullLogger"]
  Woods__Watch__Daemon_default_logger -->|method_call| NullLogger
  Woods__Watch__Daemon__NullLogger_info["Woods::Watch::Daemon::NullLogger#info"]
  Woods__Watch__Daemon__NullLogger_warn["Woods::Watch::Daemon::NullLogger#warn"]
  Woods__Watch__Daemon__NullLogger_error["Woods::Watch::Daemon::NullLogger#error"]
  Woods__Watch__Daemon__RailsReloader_enabled_["Woods::Watch::Daemon::RailsReloader#enabled?"]
  Woods__Watch__Daemon__RailsReloader_enabled_ -->|method_call| Rails
  Woods__Watch__Daemon__RailsReloader_enabled_ -->|method_call| Rails_application
  Woods__Watch__Daemon__RailsReloader_reload_["Woods::Watch::Daemon::RailsReloader#reload!"]
  Rails_application_reloader["Rails.application.reloader"]
  Woods__Watch__Daemon__RailsReloader_reload_ -->|method_call| Rails_application_reloader
  Woods__Watch__Daemon__RailsReloader_reload_ -->|method_call| Rails_application
  Woods__Watch__Daemon__RailsReloader_reload_ -->|method_call| Rails
  Woods__Watch__ListenWatcher["Woods::Watch::ListenWatcher"]
  Woods__Watch__ListenWatcher_initialize["Woods::Watch::ListenWatcher#initialize"]
  Woods__Watch__ListenWatcher_start["Woods::Watch::ListenWatcher#start"]
  Woods__Watch__ListenWatcher_stop["Woods::Watch::ListenWatcher#stop"]
  Woods__Watch__ListenWatcher_ignore_patterns["Woods::Watch::ListenWatcher#ignore_patterns"]
  Woods__Watch__ListenWatcher_ignore_patterns -->|method_call| Regexp
  Woods__Watch__ListenWatcher_sleep_until_stopped["Woods::Watch::ListenWatcher#sleep_until_stopped"]
  Woods__Watch__PollingWatcher["Woods::Watch::PollingWatcher"]
  Woods__Watch__PollingWatcher_initialize["Woods::Watch::PollingWatcher#initialize"]
  Woods__Watch__PollingWatcher_start["Woods::Watch::PollingWatcher#start"]
  Woods__Watch__PollingWatcher_stop["Woods::Watch::PollingWatcher#stop"]
  Woods__Watch__PollingWatcher_primed_now_["Woods::Watch::PollingWatcher#primed_now?"]
  Woods__Watch__PollingWatcher_poll["Woods::Watch::PollingWatcher#poll"]
  Woods__Watch__PollingWatcher_scan["Woods::Watch::PollingWatcher#scan"]
  Woods__Watch__PollingWatcher_scan -->|method_call| File
  Woods__Watch__PollingWatcher_each_watched_path["Woods::Watch::PollingWatcher#each_watched_path"]
  TreeScan["TreeScan"]
  Woods__Watch__PollingWatcher_each_watched_path -->|method_call| TreeScan
  Woods__Watch__Status["Woods::Watch::Status"]
  Woods__Watch__Status_initialize["Woods::Watch::Status#initialize"]
  Woods__Watch__Status_initialize -->|method_call| File
  Woods__Watch__Status_write["Woods::Watch::Status#write"]
  STATES["STATES"]
  Woods__Watch__Status_write -->|method_call| STATES
  Woods__Watch__Status_write -->|method_call| AtomicFile
  Woods__Watch__Status_read["Woods::Watch::Status#read"]
  Woods__Watch__Status_read -->|method_call| File
  Woods__Watch__Status_read -->|method_call| JSON
  Woods__Watch__Status_alive_["Woods::Watch::Status#alive?"]
  Woods__Watch__Status_host_identity["Woods::Watch::Status.host_identity"]
  Socket["Socket"]
  Woods__Watch__Status_host_identity -->|method_call| Socket
  Woods__Watch__Status_same_host_["Woods::Watch::Status#same_host?"]
  Woods__Watch__Status_process_alive_["Woods::Watch::Status#process_alive?"]
  Woods__Watch__Status_process_alive_ -->|method_call| Process
  Woods__Watch__Status_recent_["Woods::Watch::Status#recent?"]
  Time_parse__["Time.parse.-"]
  Woods__Watch__Status_recent_ -->|method_call| Time_parse__
  Time_parse["Time.parse"]
  Woods__Watch__Status_recent_ -->|method_call| Time_parse
  Woods__Watch__Status_recent_ -->|method_call| Time
  Woods__Watch__TreeScan["Woods::Watch::TreeScan"]
  Woods__Watch__TreeScan_each_file["Woods::Watch::TreeScan#each_file"]
  Woods__Watch__TreeScan_each_file -->|method_call| Set
  Find["Find"]
  Woods__Watch__TreeScan_each_file -->|method_call| Find
  Woods__Watch__TreeScan_visit_entry["Woods::Watch::TreeScan#visit_entry"]
  Woods__Watch__TreeScan_visit_entry -->|method_call| File
  Woods__Watch__TreeScan_descend_symlink["Woods::Watch::TreeScan#descend_symlink"]
  Woods__Watch__TreeScan_symlinked_directory_["Woods::Watch::TreeScan#symlinked_directory?"]
  Woods__Watch__TreeScan_symlinked_directory_ -->|method_call| File
  Woods__Watch__TreeScan_real_dir["Woods::Watch::TreeScan#real_dir"]
  Woods__Watch__TreeScan_real_dir -->|method_call| File
  Woods__Watch__TreeScan_skip_["Woods::Watch::TreeScan#skip?"]
  Woods__Watch__TreeScan_files["Woods::Watch::TreeScan#files"]
  Woods__Watch__TreeScan_hidden_["Woods::Watch::TreeScan#hidden?"]
  Woods__Watch__TreeScan_hidden_segment_["Woods::Watch::TreeScan#hidden_segment?"]
  NOT_IGNORED_DOTFILES["NOT_IGNORED_DOTFILES"]
  Woods__Watch__TreeScan_hidden_segment_ -->|method_call| NOT_IGNORED_DOTFILES
  NOT_IGNORED_DOTFILE_PREFIXES["NOT_IGNORED_DOTFILE_PREFIXES"]
  Woods__Watch__TreeScan_hidden_segment_ -->|method_call| NOT_IGNORED_DOTFILE_PREFIXES
  Woods__Watch__TreeScan_ignored_["Woods::Watch::TreeScan#ignored?"]
  Woods__Watch__WatcherError["Woods::Watch::WatcherError"]
  Woods__Watch__WatcherError -->|inheritance| Woods__Error
  Woods__Watch__Watcher["Woods::Watch::Watcher"]
  Woods__Watch__Watcher_build["Woods::Watch::Watcher#build"]
  ListenWatcher["ListenWatcher"]
  Woods__Watch__Watcher_build -->|method_call| ListenWatcher
  PollingWatcher["PollingWatcher"]
  Woods__Watch__Watcher_build -->|method_call| PollingWatcher
  Woods__Watch__Watcher_containerized_["Woods::Watch::Watcher#containerized?"]
  Woods__Watch__Watcher_containerized_ -->|method_call| ENV
  Woods__Watch__Watcher_containerized_ -->|method_call| ENV___
  Woods__Watch__Watcher_containerized_ -->|method_call| File
```
