# Call Graph

```mermaid
graph TD
  CodebaseIndex["CodebaseIndex"]
  CodebaseIndex__Ast["CodebaseIndex::Ast"]
  CodebaseIndex__Ast__CallSiteExtractor["CodebaseIndex::Ast::CallSiteExtractor"]
  CodebaseIndex__Ast__CallSiteExtractor_extract["CodebaseIndex::Ast::CallSiteExtractor#extract"]
  CodebaseIndex__Ast__CallSiteExtractor_extract_significant["CodebaseIndex::Ast::CallSiteExtractor#extract_significant"]
  Set["Set"]
  CodebaseIndex__Ast__CallSiteExtractor_extract_significant -->|method_call| Set
  INSIGNIFICANT_METHODS["INSIGNIFICANT_METHODS"]
  CodebaseIndex__Ast__CallSiteExtractor_extract_significant -->|method_call| INSIGNIFICANT_METHODS
  CodebaseIndex__Ast__CallSiteExtractor_collect_calls["CodebaseIndex::Ast::CallSiteExtractor#collect_calls"]
  CodebaseIndex__Ast__MethodExtractor["CodebaseIndex::Ast::MethodExtractor"]
  CodebaseIndex__Ast__MethodExtractor_initialize["CodebaseIndex::Ast::MethodExtractor#initialize"]
  Parser["Parser"]
  CodebaseIndex__Ast__MethodExtractor_initialize -->|method_call| Parser
  CodebaseIndex__Ast__MethodExtractor_extract_method["CodebaseIndex::Ast::MethodExtractor#extract_method"]
  CodebaseIndex__Ast__MethodExtractor_extract_all_methods["CodebaseIndex::Ast::MethodExtractor#extract_all_methods"]
  CodebaseIndex__Ast__MethodExtractor_extract_method_source["CodebaseIndex::Ast::MethodExtractor#extract_method_source"]
  CodebaseIndex__Error["CodebaseIndex::Error"]
  StandardError["StandardError"]
  CodebaseIndex__Error -->|inheritance| StandardError
  CodebaseIndex__ExtractionError["CodebaseIndex::ExtractionError"]
  Error["Error"]
  CodebaseIndex__ExtractionError -->|inheritance| Error
  CodebaseIndex__Ast__Parser["CodebaseIndex::Ast::Parser"]
  CodebaseIndex__Ast__Parser_parse["CodebaseIndex::Ast::Parser#parse"]
  CodebaseIndex__Ast__Parser_prism_available_["CodebaseIndex::Ast::Parser#prism_available?"]
  CodebaseIndex__Ast__Parser_parse_with_prism["CodebaseIndex::Ast::Parser#parse_with_prism"]
  Prism["Prism"]
  CodebaseIndex__Ast__Parser_parse_with_prism -->|method_call| Prism
  CodebaseIndex__Ast__Parser_parse_with_parser_gem["CodebaseIndex::Ast::Parser#parse_with_parser_gem"]
  Parser__Source__Buffer["Parser::Source::Buffer"]
  CodebaseIndex__Ast__Parser_parse_with_parser_gem -->|method_call| Parser__Source__Buffer
  Parser__CurrentRuby["Parser::CurrentRuby"]
  CodebaseIndex__Ast__Parser_parse_with_parser_gem -->|method_call| Parser__CurrentRuby
  CodebaseIndex__Ast__Parser_convert_prism_node["CodebaseIndex::Ast::Parser#convert_prism_node"]
  Node["Node"]
  CodebaseIndex__Ast__Parser_convert_prism_node -->|method_call| Node
  CodebaseIndex__Ast__Parser_convert_prism_class["CodebaseIndex::Ast::Parser#convert_prism_class"]
  CodebaseIndex__Ast__Parser_convert_prism_class -->|method_call| Node
  CodebaseIndex__Ast__Parser_convert_prism_module["CodebaseIndex::Ast::Parser#convert_prism_module"]
  CodebaseIndex__Ast__Parser_convert_prism_module -->|method_call| Node
  CodebaseIndex__Ast__Parser_convert_prism_def["CodebaseIndex::Ast::Parser#convert_prism_def"]
  CodebaseIndex__Ast__Parser_convert_prism_def -->|method_call| Node
  CodebaseIndex__Ast__Parser_convert_prism_call["CodebaseIndex::Ast::Parser#convert_prism_call"]
  CodebaseIndex__Ast__Parser_convert_prism_call -->|method_call| Node
  CodebaseIndex__Ast__Parser_convert_prism_constant_path["CodebaseIndex::Ast::Parser#convert_prism_constant_path"]
  CodebaseIndex__Ast__Parser_convert_prism_constant_path -->|method_call| Node
  CodebaseIndex__Ast__Parser_convert_prism_if["CodebaseIndex::Ast::Parser#convert_prism_if"]
  CodebaseIndex__Ast__Parser_convert_prism_if -->|method_call| Node
  CodebaseIndex__Ast__Parser_convert_prism_unless["CodebaseIndex::Ast::Parser#convert_prism_unless"]
  CodebaseIndex__Ast__Parser_convert_prism_unless -->|method_call| Node
  CodebaseIndex__Ast__Parser_convert_prism_case["CodebaseIndex::Ast::Parser#convert_prism_case"]
  CodebaseIndex__Ast__Parser_convert_prism_case -->|method_call| Node
  CodebaseIndex__Ast__Parser_convert_prism_children["CodebaseIndex::Ast::Parser#convert_prism_children"]
  CodebaseIndex__Ast__Parser_extract_prism_generic_children["CodebaseIndex::Ast::Parser#extract_prism_generic_children"]
  CodebaseIndex__Ast__Parser_line_for_prism["CodebaseIndex::Ast::Parser#line_for_prism"]
  CodebaseIndex__Ast__Parser_end_line_for_prism["CodebaseIndex::Ast::Parser#end_line_for_prism"]
  CodebaseIndex__Ast__Parser_extract_prism_source_span["CodebaseIndex::Ast::Parser#extract_prism_source_span"]
  CodebaseIndex__Ast__Parser_extract_prism_source_text["CodebaseIndex::Ast::Parser#extract_prism_source_text"]
  CodebaseIndex__Ast__Parser_extract_prism_receiver_text["CodebaseIndex::Ast::Parser#extract_prism_receiver_text"]
  CodebaseIndex__Ast__Parser_extract_const_path_text["CodebaseIndex::Ast::Parser#extract_const_path_text"]
  CodebaseIndex__Ast__Parser_extract_const_name["CodebaseIndex::Ast::Parser#extract_const_name"]
  CodebaseIndex__Ast__Parser_convert_parser_node["CodebaseIndex::Ast::Parser#convert_parser_node"]
  CodebaseIndex__Ast__Parser_convert_parser_node -->|method_call| Node
  CodebaseIndex__Ast__Parser_extract_parser_source_span["CodebaseIndex::Ast::Parser#extract_parser_source_span"]
  CodebaseIndex__Ast__Parser_extract_parser_source_text["CodebaseIndex::Ast::Parser#extract_parser_source_text"]
  CodebaseIndex__Ast__Parser_extract_parser_receiver_text["CodebaseIndex::Ast::Parser#extract_parser_receiver_text"]
  CodebaseIndex__Ast__Parser_extract_parser_const_name["CodebaseIndex::Ast::Parser#extract_parser_const_name"]
  CodebaseIndex__Builder["CodebaseIndex::Builder"]
  CodebaseIndex__Builder_preset_config["CodebaseIndex::Builder.preset_config"]
  PRESETS["PRESETS"]
  CodebaseIndex__Builder_preset_config -->|method_call| PRESETS
  Configuration["Configuration"]
  CodebaseIndex__Builder_preset_config -->|method_call| Configuration
  CodebaseIndex__Builder_initialize["CodebaseIndex::Builder#initialize"]
  CodebaseIndex__Builder_build_retriever["CodebaseIndex::Builder#build_retriever"]
  Retriever["Retriever"]
  CodebaseIndex__Builder_build_retriever -->|method_call| Retriever
  CodebaseIndex__Builder_build_vector_store["CodebaseIndex::Builder#build_vector_store"]
  Storage__VectorStore__InMemory["Storage::VectorStore::InMemory"]
  CodebaseIndex__Builder_build_vector_store -->|method_call| Storage__VectorStore__InMemory
  Storage__VectorStore__Pgvector["Storage::VectorStore::Pgvector"]
  CodebaseIndex__Builder_build_vector_store -->|method_call| Storage__VectorStore__Pgvector
  Storage__VectorStore__Qdrant["Storage::VectorStore::Qdrant"]
  CodebaseIndex__Builder_build_vector_store -->|method_call| Storage__VectorStore__Qdrant
  CodebaseIndex__Builder_build_embedding_provider["CodebaseIndex::Builder#build_embedding_provider"]
  Embedding__Provider__OpenAI["Embedding::Provider::OpenAI"]
  CodebaseIndex__Builder_build_embedding_provider -->|method_call| Embedding__Provider__OpenAI
  Embedding__Provider__Ollama["Embedding::Provider::Ollama"]
  CodebaseIndex__Builder_build_embedding_provider -->|method_call| Embedding__Provider__Ollama
  CodebaseIndex__Builder_build_metadata_store["CodebaseIndex::Builder#build_metadata_store"]
  Storage__MetadataStore__InMemory["Storage::MetadataStore::InMemory"]
  CodebaseIndex__Builder_build_metadata_store -->|method_call| Storage__MetadataStore__InMemory
  Storage__MetadataStore__SQLite["Storage::MetadataStore::SQLite"]
  CodebaseIndex__Builder_build_metadata_store -->|method_call| Storage__MetadataStore__SQLite
  CodebaseIndex__Builder_build_graph_store["CodebaseIndex::Builder#build_graph_store"]
  Storage__GraphStore__Memory["Storage::GraphStore::Memory"]
  CodebaseIndex__Builder_build_graph_store -->|method_call| Storage__GraphStore__Memory
  CodebaseIndex__Chunking["CodebaseIndex::Chunking"]
  CodebaseIndex__Chunking__Chunk["CodebaseIndex::Chunking::Chunk"]
  CodebaseIndex__Chunking__Chunk_initialize["CodebaseIndex::Chunking::Chunk#initialize"]
  CodebaseIndex__Chunking__Chunk_token_count["CodebaseIndex::Chunking::Chunk#token_count"]
  CodebaseIndex__Chunking__Chunk_content_hash["CodebaseIndex::Chunking::Chunk#content_hash"]
  Digest__SHA256["Digest::SHA256"]
  CodebaseIndex__Chunking__Chunk_content_hash -->|method_call| Digest__SHA256
  CodebaseIndex__Chunking__Chunk_identifier["CodebaseIndex::Chunking::Chunk#identifier"]
  CodebaseIndex__Chunking__Chunk_empty_["CodebaseIndex::Chunking::Chunk#empty?"]
  CodebaseIndex__Chunking__Chunk_to_h["CodebaseIndex::Chunking::Chunk#to_h"]
  CodebaseIndex__Chunking__SemanticChunker["CodebaseIndex::Chunking::SemanticChunker"]
  CodebaseIndex__Chunking__ModelChunker["CodebaseIndex::Chunking::ModelChunker"]
  CodebaseIndex__Chunking__ControllerChunker["CodebaseIndex::Chunking::ControllerChunker"]
  CodebaseIndex__Chunking__SemanticChunker_initialize["CodebaseIndex::Chunking::SemanticChunker#initialize"]
  CodebaseIndex__Chunking__SemanticChunker_chunk["CodebaseIndex::Chunking::SemanticChunker#chunk"]
  ModelChunker_new["ModelChunker.new"]
  CodebaseIndex__Chunking__SemanticChunker_chunk -->|method_call| ModelChunker_new
  ModelChunker["ModelChunker"]
  CodebaseIndex__Chunking__SemanticChunker_chunk -->|method_call| ModelChunker
  ControllerChunker_new["ControllerChunker.new"]
  CodebaseIndex__Chunking__SemanticChunker_chunk -->|method_call| ControllerChunker_new
  ControllerChunker["ControllerChunker"]
  CodebaseIndex__Chunking__SemanticChunker_chunk -->|method_call| ControllerChunker
  CodebaseIndex__Chunking__SemanticChunker_build_whole_chunk["CodebaseIndex::Chunking::SemanticChunker#build_whole_chunk"]
  Chunk["Chunk"]
  CodebaseIndex__Chunking__SemanticChunker_build_whole_chunk -->|method_call| Chunk
  CodebaseIndex__Chunking__ModelChunker_initialize["CodebaseIndex::Chunking::ModelChunker#initialize"]
  CodebaseIndex__Chunking__ModelChunker_chunk["CodebaseIndex::Chunking::ModelChunker#chunk"]
  CodebaseIndex__Chunking__ModelChunker_build_chunks["CodebaseIndex::Chunking::ModelChunker#build_chunks"]
  SEMANTIC_SECTIONS["SEMANTIC_SECTIONS"]
  CodebaseIndex__Chunking__ModelChunker_build_chunks -->|method_call| SEMANTIC_SECTIONS
  CodebaseIndex__Chunking__ModelChunker_classify_lines["CodebaseIndex::Chunking::ModelChunker#classify_lines"]
  CodebaseIndex__Chunking__ModelChunker_empty_sections["CodebaseIndex::Chunking::ModelChunker#empty_sections"]
  CodebaseIndex__Chunking__ModelChunker_track_method_line["CodebaseIndex::Chunking::ModelChunker#track_method_line"]
  CodebaseIndex__Chunking__ModelChunker_update_method_depth["CodebaseIndex::Chunking::ModelChunker#update_method_depth"]
  CodebaseIndex__Chunking__ModelChunker_classify_line["CodebaseIndex::Chunking::ModelChunker#classify_line"]
  CodebaseIndex__Chunking__ModelChunker_detect_semantic_section["CodebaseIndex::Chunking::ModelChunker#detect_semantic_section"]
  SECTION_PATTERNS["SECTION_PATTERNS"]
  CodebaseIndex__Chunking__ModelChunker_detect_semantic_section -->|method_call| SECTION_PATTERNS
  CodebaseIndex__Chunking__ModelChunker_start_method["CodebaseIndex::Chunking::ModelChunker#start_method"]
  CodebaseIndex__Chunking__ModelChunker_assign_fallback["CodebaseIndex::Chunking::ModelChunker#assign_fallback"]
  CodebaseIndex__Chunking__ModelChunker_build_chunk["CodebaseIndex::Chunking::ModelChunker#build_chunk"]
  CodebaseIndex__Chunking__ModelChunker_build_chunk -->|method_call| Chunk
  CodebaseIndex__Chunking__ControllerChunker_initialize["CodebaseIndex::Chunking::ControllerChunker#initialize"]
  CodebaseIndex__Chunking__ControllerChunker_chunk["CodebaseIndex::Chunking::ControllerChunker#chunk"]
  CodebaseIndex__Chunking__ControllerChunker_parse_lines["CodebaseIndex::Chunking::ControllerChunker#parse_lines"]
  CodebaseIndex__Chunking__ControllerChunker_track_action_line["CodebaseIndex::Chunking::ControllerChunker#track_action_line"]
  CodebaseIndex__Chunking__ControllerChunker_classify_controller_line["CodebaseIndex::Chunking::ControllerChunker#classify_controller_line"]
  CodebaseIndex__Chunking__ControllerChunker_start_action["CodebaseIndex::Chunking::ControllerChunker#start_action"]
  CodebaseIndex__Chunking__ControllerChunker_build_chunks["CodebaseIndex::Chunking::ControllerChunker#build_chunks"]
  CodebaseIndex__Chunking__ControllerChunker_build_chunk["CodebaseIndex::Chunking::ControllerChunker#build_chunk"]
  CodebaseIndex__Chunking__ControllerChunker_build_chunk -->|method_call| Chunk
  CodebaseIndex__Console["CodebaseIndex::Console"]
  CodebaseIndex__Console__Adapters["CodebaseIndex::Console::Adapters"]
  CodebaseIndex__Console__Adapters__CacheAdapter["CodebaseIndex::Console::Adapters::CacheAdapter"]
  CodebaseIndex__Console__Adapters__CacheAdapter_detect["CodebaseIndex::Console::Adapters::CacheAdapter#detect"]
  Rails["Rails"]
  CodebaseIndex__Console__Adapters__CacheAdapter_detect -->|method_call| Rails
  Rails_cache_class_name["Rails.cache.class.name"]
  CodebaseIndex__Console__Adapters__CacheAdapter_detect -->|method_call| Rails_cache_class_name
  Rails_cache_class["Rails.cache.class"]
  CodebaseIndex__Console__Adapters__CacheAdapter_detect -->|method_call| Rails_cache_class
  Rails_cache["Rails.cache"]
  CodebaseIndex__Console__Adapters__CacheAdapter_detect -->|method_call| Rails_cache
  STORE_PATTERNS["STORE_PATTERNS"]
  CodebaseIndex__Console__Adapters__CacheAdapter_detect -->|method_call| STORE_PATTERNS
  CodebaseIndex__Console__Adapters__CacheAdapter_stats["CodebaseIndex::Console::Adapters::CacheAdapter#stats"]
  CodebaseIndex__Console__Adapters__CacheAdapter_info["CodebaseIndex::Console::Adapters::CacheAdapter#info"]
  CodebaseIndex__Console__Adapters__GoodJobAdapter["CodebaseIndex::Console::Adapters::GoodJobAdapter"]
  CodebaseIndex__Console__Adapters__GoodJobAdapter_available_["CodebaseIndex::Console::Adapters::GoodJobAdapter.available?"]
  CodebaseIndex__Console__Adapters__GoodJobAdapter_queue_stats["CodebaseIndex::Console::Adapters::GoodJobAdapter#queue_stats"]
  CodebaseIndex__Console__Adapters__GoodJobAdapter_recent_failures["CodebaseIndex::Console::Adapters::GoodJobAdapter#recent_failures"]
  CodebaseIndex__Console__Adapters__GoodJobAdapter_find_job["CodebaseIndex::Console::Adapters::GoodJobAdapter#find_job"]
  CodebaseIndex__Console__Adapters__GoodJobAdapter_scheduled_jobs["CodebaseIndex::Console::Adapters::GoodJobAdapter#scheduled_jobs"]
  CodebaseIndex__Console__Adapters__GoodJobAdapter_retry_job["CodebaseIndex::Console::Adapters::GoodJobAdapter#retry_job"]
  CodebaseIndex__Console__Adapters__SidekiqAdapter["CodebaseIndex::Console::Adapters::SidekiqAdapter"]
  CodebaseIndex__Console__Adapters__SidekiqAdapter_available_["CodebaseIndex::Console::Adapters::SidekiqAdapter.available?"]
  CodebaseIndex__Console__Adapters__SidekiqAdapter_queue_stats["CodebaseIndex::Console::Adapters::SidekiqAdapter#queue_stats"]
  CodebaseIndex__Console__Adapters__SidekiqAdapter_recent_failures["CodebaseIndex::Console::Adapters::SidekiqAdapter#recent_failures"]
  CodebaseIndex__Console__Adapters__SidekiqAdapter_find_job["CodebaseIndex::Console::Adapters::SidekiqAdapter#find_job"]
  CodebaseIndex__Console__Adapters__SidekiqAdapter_scheduled_jobs["CodebaseIndex::Console::Adapters::SidekiqAdapter#scheduled_jobs"]
  CodebaseIndex__Console__Adapters__SidekiqAdapter_retry_job["CodebaseIndex::Console::Adapters::SidekiqAdapter#retry_job"]
  CodebaseIndex__Console__Adapters__SolidQueueAdapter["CodebaseIndex::Console::Adapters::SolidQueueAdapter"]
  CodebaseIndex__Console__Adapters__SolidQueueAdapter_available_["CodebaseIndex::Console::Adapters::SolidQueueAdapter.available?"]
  CodebaseIndex__Console__Adapters__SolidQueueAdapter_queue_stats["CodebaseIndex::Console::Adapters::SolidQueueAdapter#queue_stats"]
  CodebaseIndex__Console__Adapters__SolidQueueAdapter_recent_failures["CodebaseIndex::Console::Adapters::SolidQueueAdapter#recent_failures"]
  CodebaseIndex__Console__Adapters__SolidQueueAdapter_find_job["CodebaseIndex::Console::Adapters::SolidQueueAdapter#find_job"]
  CodebaseIndex__Console__Adapters__SolidQueueAdapter_scheduled_jobs["CodebaseIndex::Console::Adapters::SolidQueueAdapter#scheduled_jobs"]
  CodebaseIndex__Console__Adapters__SolidQueueAdapter_retry_job["CodebaseIndex::Console::Adapters::SolidQueueAdapter#retry_job"]
  CodebaseIndex__Console__AuditLogger["CodebaseIndex::Console::AuditLogger"]
  CodebaseIndex__Console__AuditLogger_initialize["CodebaseIndex::Console::AuditLogger#initialize"]
  CodebaseIndex__Console__AuditLogger_log["CodebaseIndex::Console::AuditLogger#log"]
  File["File"]
  CodebaseIndex__Console__AuditLogger_log -->|method_call| File
  CodebaseIndex__Console__AuditLogger_entries["CodebaseIndex::Console::AuditLogger#entries"]
  CodebaseIndex__Console__AuditLogger_entries -->|method_call| File
  File_readlines["File.readlines"]
  CodebaseIndex__Console__AuditLogger_entries -->|method_call| File_readlines
  JSON["JSON"]
  CodebaseIndex__Console__AuditLogger_entries -->|method_call| JSON
  CodebaseIndex__Console__AuditLogger_size["CodebaseIndex::Console::AuditLogger#size"]
  CodebaseIndex__Console__AuditLogger_ensure_directory_["CodebaseIndex::Console::AuditLogger#ensure_directory!"]
  CodebaseIndex__Console__AuditLogger_ensure_directory_ -->|method_call| File
  FileUtils["FileUtils"]
  CodebaseIndex__Console__AuditLogger_ensure_directory_ -->|method_call| FileUtils
  CodebaseIndex__Console__Bridge["CodebaseIndex::Console::Bridge"]
  CodebaseIndex__Console__Bridge_initialize["CodebaseIndex::Console::Bridge#initialize"]
  CodebaseIndex__Console__Bridge_run["CodebaseIndex::Console::Bridge#run"]
  CodebaseIndex__Console__Bridge_handle_request["CodebaseIndex::Console::Bridge#handle_request"]
  SUPPORTED_TOOLS["SUPPORTED_TOOLS"]
  CodebaseIndex__Console__Bridge_handle_request -->|method_call| SUPPORTED_TOOLS
  Process["Process"]
  CodebaseIndex__Console__Bridge_handle_request -->|method_call| Process
  Process_clock_gettime["Process.clock_gettime"]
  CodebaseIndex__Console__Bridge_handle_request -->|method_call| Process_clock_gettime
  CodebaseIndex__Console__Bridge_parse_request["CodebaseIndex::Console::Bridge#parse_request"]
  CodebaseIndex__Console__Bridge_parse_request -->|method_call| JSON
  CodebaseIndex__Console__Bridge_dispatch["CodebaseIndex::Console::Bridge#dispatch"]
  TOOL_HANDLERS["TOOL_HANDLERS"]
  CodebaseIndex__Console__Bridge_dispatch -->|method_call| TOOL_HANDLERS
  CodebaseIndex__Console__Bridge_validate_model_param["CodebaseIndex::Console::Bridge#validate_model_param"]
  CodebaseIndex__Console__Bridge_handle_count["CodebaseIndex::Console::Bridge#handle_count"]
  CodebaseIndex__Console__Bridge_handle_sample["CodebaseIndex::Console::Bridge#handle_sample"]
  CodebaseIndex__Console__Bridge_handle_find["CodebaseIndex::Console::Bridge#handle_find"]
  CodebaseIndex__Console__Bridge_handle_pluck["CodebaseIndex::Console::Bridge#handle_pluck"]
  CodebaseIndex__Console__Bridge_handle_aggregate["CodebaseIndex::Console::Bridge#handle_aggregate"]
  CodebaseIndex__Console__Bridge_handle_association_count["CodebaseIndex::Console::Bridge#handle_association_count"]
  CodebaseIndex__Console__Bridge_handle_schema["CodebaseIndex::Console::Bridge#handle_schema"]
  CodebaseIndex__Console__Bridge_handle_recent["CodebaseIndex::Console::Bridge#handle_recent"]
  CodebaseIndex__Console__Bridge_handle_status["CodebaseIndex::Console::Bridge#handle_status"]
  CodebaseIndex__Console__Bridge_error_response["CodebaseIndex::Console::Bridge#error_response"]
  CodebaseIndex__Console__Bridge_write_response["CodebaseIndex::Console::Bridge#write_response"]
  CodebaseIndex__Console__ConfirmationDeniedError["CodebaseIndex::Console::ConfirmationDeniedError"]
  CodebaseIndex__Console__ConfirmationDeniedError -->|inheritance| CodebaseIndex__Error
  CodebaseIndex__Console__Confirmation["CodebaseIndex::Console::Confirmation"]
  CodebaseIndex__Console__Confirmation_initialize["CodebaseIndex::Console::Confirmation#initialize"]
  VALID_MODES["VALID_MODES"]
  CodebaseIndex__Console__Confirmation_initialize -->|method_call| VALID_MODES
  CodebaseIndex__Console__Confirmation_request_confirmation["CodebaseIndex::Console::Confirmation#request_confirmation"]
  CodebaseIndex__Console__Confirmation_evaluate["CodebaseIndex::Console::Confirmation#evaluate"]
  CodebaseIndex__Console__ConnectionError["CodebaseIndex::Console::ConnectionError"]
  CodebaseIndex__Console__ConnectionError -->|inheritance| CodebaseIndex__Error
  CodebaseIndex__Console__ConnectionManager["CodebaseIndex::Console::ConnectionManager"]
  CodebaseIndex__Console__ConnectionManager_initialize["CodebaseIndex::Console::ConnectionManager#initialize"]
  CodebaseIndex__Console__ConnectionManager_connect_["CodebaseIndex::Console::ConnectionManager#connect!"]
  Dir["Dir"]
  CodebaseIndex__Console__ConnectionManager_connect_ -->|method_call| Dir
  Open3["Open3"]
  CodebaseIndex__Console__ConnectionManager_connect_ -->|method_call| Open3
  Time["Time"]
  CodebaseIndex__Console__ConnectionManager_connect_ -->|method_call| Time
  CodebaseIndex__Console__ConnectionManager_disconnect_["CodebaseIndex::Console::ConnectionManager#disconnect!"]
  CodebaseIndex__Console__ConnectionManager_send_request["CodebaseIndex::Console::ConnectionManager#send_request"]
  CodebaseIndex__Console__ConnectionManager_send_request -->|method_call| Time
  CodebaseIndex__Console__ConnectionManager_send_request -->|method_call| JSON
  CodebaseIndex__Console__ConnectionManager_alive_["CodebaseIndex::Console::ConnectionManager#alive?"]
  CodebaseIndex__Console__ConnectionManager_heartbeat_needed_["CodebaseIndex::Console::ConnectionManager#heartbeat_needed?"]
  Time_now["Time.now"]
  CodebaseIndex__Console__ConnectionManager_heartbeat_needed_ -->|method_call| Time_now
  CodebaseIndex__Console__ConnectionManager_heartbeat_needed_ -->|method_call| Time
  CodebaseIndex__Console__ConnectionManager_build_command["CodebaseIndex::Console::ConnectionManager#build_command"]
  CodebaseIndex__Console__ConnectionManager_build_docker_command["CodebaseIndex::Console::ConnectionManager#build_docker_command"]
  CodebaseIndex__Console__ConnectionManager_build_ssh_command["CodebaseIndex::Console::ConnectionManager#build_ssh_command"]
  CodebaseIndex__Console__ConnectionManager_build_direct_command["CodebaseIndex::Console::ConnectionManager#build_direct_command"]
  CodebaseIndex__Console__ConnectionManager_ensure_connected_["CodebaseIndex::Console::ConnectionManager#ensure_connected!"]
  CodebaseIndex__Console__ConnectionManager_reconnect_or_raise_["CodebaseIndex::Console::ConnectionManager#reconnect_or_raise!"]
  CodebaseIndex__Console__ValidationError["CodebaseIndex::Console::ValidationError"]
  CodebaseIndex__Console__ValidationError -->|inheritance| CodebaseIndex__Error
  CodebaseIndex__Console__ModelValidator["CodebaseIndex::Console::ModelValidator"]
  CodebaseIndex__Console__ModelValidator_initialize["CodebaseIndex::Console::ModelValidator#initialize"]
  CodebaseIndex__Console__ModelValidator_validate_model_["CodebaseIndex::Console::ModelValidator#validate_model!"]
  CodebaseIndex__Console__ModelValidator_validate_column_["CodebaseIndex::Console::ModelValidator#validate_column!"]
  CodebaseIndex__Console__ModelValidator_validate_columns_["CodebaseIndex::Console::ModelValidator#validate_columns!"]
  CodebaseIndex__Console__ModelValidator_model_names["CodebaseIndex::Console::ModelValidator#model_names"]
  CodebaseIndex__Console__ModelValidator_columns_for["CodebaseIndex::Console::ModelValidator#columns_for"]
  ActiveRecord["ActiveRecord"]
  ActiveRecord__Rollback["ActiveRecord::Rollback"]
  ActiveRecord__Rollback -->|inheritance| StandardError
  CodebaseIndex__Console__SafeContext["CodebaseIndex::Console::SafeContext"]
  CodebaseIndex__Console__SafeContext_initialize["CodebaseIndex::Console::SafeContext#initialize"]
  CodebaseIndex__Console__SafeContext_execute["CodebaseIndex::Console::SafeContext#execute"]
  CodebaseIndex__Console__SafeContext_redact["CodebaseIndex::Console::SafeContext#redact"]
  CodebaseIndex__Console__SafeContext_set_timeout["CodebaseIndex::Console::SafeContext#set_timeout"]
  CodebaseIndex__Console__Server["CodebaseIndex::Console::Server"]
  CodebaseIndex__Console__SqlValidationError["CodebaseIndex::Console::SqlValidationError"]
  CodebaseIndex__Console__SqlValidationError -->|inheritance| CodebaseIndex__Error
  CodebaseIndex__Console__SqlValidator["CodebaseIndex::Console::SqlValidator"]
  CodebaseIndex__Console__SqlValidator_validate_["CodebaseIndex::Console::SqlValidator#validate!"]
  CodebaseIndex__Console__SqlValidator_valid_["CodebaseIndex::Console::SqlValidator#valid?"]
  CodebaseIndex__Console__SqlValidator_contains_multiple_statements_["CodebaseIndex::Console::SqlValidator#contains_multiple_statements?"]
  CodebaseIndex__Console__SqlValidator_check_forbidden_keywords_["CodebaseIndex::Console::SqlValidator#check_forbidden_keywords!"]
  FORBIDDEN_KEYWORDS["FORBIDDEN_KEYWORDS"]
  CodebaseIndex__Console__SqlValidator_check_forbidden_keywords_ -->|method_call| FORBIDDEN_KEYWORDS
  CodebaseIndex__Console__SqlValidator_check_body_forbidden_keywords_["CodebaseIndex::Console::SqlValidator#check_body_forbidden_keywords!"]
  BODY_FORBIDDEN_KEYWORDS["BODY_FORBIDDEN_KEYWORDS"]
  CodebaseIndex__Console__SqlValidator_check_body_forbidden_keywords_ -->|method_call| BODY_FORBIDDEN_KEYWORDS
  CodebaseIndex__Console__SqlValidator_check_writable_ctes_["CodebaseIndex::Console::SqlValidator#check_writable_ctes!"]
  CodebaseIndex__Console__SqlValidator_check_dangerous_functions_["CodebaseIndex::Console::SqlValidator#check_dangerous_functions!"]
  DANGEROUS_FUNCTIONS["DANGEROUS_FUNCTIONS"]
  CodebaseIndex__Console__SqlValidator_check_dangerous_functions_ -->|method_call| DANGEROUS_FUNCTIONS
  CodebaseIndex__Console__SqlValidator_check_forbidden_keywords_in_body_["CodebaseIndex::Console::SqlValidator#check_forbidden_keywords_in_body!"]
  CodebaseIndex__Console__SqlValidator_check_forbidden_keywords_in_body_ -->|method_call| FORBIDDEN_KEYWORDS
  CodebaseIndex__Console__Tools["CodebaseIndex::Console::Tools"]
  CodebaseIndex__Console__Tools__Tier1["CodebaseIndex::Console::Tools::Tier1"]
  CodebaseIndex__Console__Tools__Tier1_console_count["CodebaseIndex::Console::Tools::Tier1#console_count"]
  CodebaseIndex__Console__Tools__Tier1_console_sample["CodebaseIndex::Console::Tools::Tier1#console_sample"]
  CodebaseIndex__Console__Tools__Tier1_console_find["CodebaseIndex::Console::Tools::Tier1#console_find"]
  CodebaseIndex__Console__Tools__Tier1_console_pluck["CodebaseIndex::Console::Tools::Tier1#console_pluck"]
  CodebaseIndex__Console__Tools__Tier1_console_aggregate["CodebaseIndex::Console::Tools::Tier1#console_aggregate"]
  CodebaseIndex__Console__Tools__Tier1_console_association_count["CodebaseIndex::Console::Tools::Tier1#console_association_count"]
  CodebaseIndex__Console__Tools__Tier1_console_schema["CodebaseIndex::Console::Tools::Tier1#console_schema"]
  CodebaseIndex__Console__Tools__Tier1_console_recent["CodebaseIndex::Console::Tools::Tier1#console_recent"]
  CodebaseIndex__Console__Tools__Tier1_console_status["CodebaseIndex::Console::Tools::Tier1#console_status"]
  CodebaseIndex__Console__Tools__Tier2["CodebaseIndex::Console::Tools::Tier2"]
  CodebaseIndex__Console__Tools__Tier2_console_diagnose_model["CodebaseIndex::Console::Tools::Tier2#console_diagnose_model"]
  CodebaseIndex__Console__Tools__Tier2_console_data_snapshot["CodebaseIndex::Console::Tools::Tier2#console_data_snapshot"]
  CodebaseIndex__Console__Tools__Tier2_console_validate_record["CodebaseIndex::Console::Tools::Tier2#console_validate_record"]
  CodebaseIndex__Console__Tools__Tier2_console_check_setting["CodebaseIndex::Console::Tools::Tier2#console_check_setting"]
  CodebaseIndex__Console__Tools__Tier2_console_update_setting["CodebaseIndex::Console::Tools::Tier2#console_update_setting"]
  CodebaseIndex__Console__Tools__Tier2_console_check_policy["CodebaseIndex::Console::Tools::Tier2#console_check_policy"]
  CodebaseIndex__Console__Tools__Tier2_console_validate_with["CodebaseIndex::Console::Tools::Tier2#console_validate_with"]
  CodebaseIndex__Console__Tools__Tier2_console_check_eligibility["CodebaseIndex::Console::Tools::Tier2#console_check_eligibility"]
  CodebaseIndex__Console__Tools__Tier2_console_decorate["CodebaseIndex::Console::Tools::Tier2#console_decorate"]
  CodebaseIndex__Console__Tools__Tier3["CodebaseIndex::Console::Tools::Tier3"]
  CodebaseIndex__Console__Tools__Tier3_console_slow_endpoints["CodebaseIndex::Console::Tools::Tier3#console_slow_endpoints"]
  CodebaseIndex__Console__Tools__Tier3_console_error_rates["CodebaseIndex::Console::Tools::Tier3#console_error_rates"]
  CodebaseIndex__Console__Tools__Tier3_console_throughput["CodebaseIndex::Console::Tools::Tier3#console_throughput"]
  CodebaseIndex__Console__Tools__Tier3_console_job_queues["CodebaseIndex::Console::Tools::Tier3#console_job_queues"]
  CodebaseIndex__Console__Tools__Tier3_console_job_failures["CodebaseIndex::Console::Tools::Tier3#console_job_failures"]
  CodebaseIndex__Console__Tools__Tier3_console_job_find["CodebaseIndex::Console::Tools::Tier3#console_job_find"]
  CodebaseIndex__Console__Tools__Tier3_console_job_schedule["CodebaseIndex::Console::Tools::Tier3#console_job_schedule"]
  CodebaseIndex__Console__Tools__Tier3_console_redis_info["CodebaseIndex::Console::Tools::Tier3#console_redis_info"]
  CodebaseIndex__Console__Tools__Tier3_console_cache_stats["CodebaseIndex::Console::Tools::Tier3#console_cache_stats"]
  CodebaseIndex__Console__Tools__Tier3_console_channel_status["CodebaseIndex::Console::Tools::Tier3#console_channel_status"]
  CodebaseIndex__Console__Tools__Tier4["CodebaseIndex::Console::Tools::Tier4"]
  CodebaseIndex__Console__Tools__Tier4_console_eval["CodebaseIndex::Console::Tools::Tier4#console_eval"]
  CodebaseIndex__Console__Tools__Tier4_console_sql["CodebaseIndex::Console::Tools::Tier4#console_sql"]
  CodebaseIndex__Console__Tools__Tier4_console_query["CodebaseIndex::Console::Tools::Tier4#console_query"]
  CodebaseIndex__Coordination["CodebaseIndex::Coordination"]
  CodebaseIndex__Coordination__LockError["CodebaseIndex::Coordination::LockError"]
  CodebaseIndex__Coordination__LockError -->|inheritance| CodebaseIndex__Error
  CodebaseIndex__Coordination__PipelineLock["CodebaseIndex::Coordination::PipelineLock"]
  CodebaseIndex__Coordination__PipelineLock_initialize["CodebaseIndex::Coordination::PipelineLock#initialize"]
  CodebaseIndex__Coordination__PipelineLock_initialize -->|method_call| File
  CodebaseIndex__Coordination__PipelineLock_acquire["CodebaseIndex::Coordination::PipelineLock#acquire"]
  CodebaseIndex__Coordination__PipelineLock_acquire -->|method_call| FileUtils
  CodebaseIndex__Coordination__PipelineLock_acquire -->|method_call| File
  CodebaseIndex__Coordination__PipelineLock_release["CodebaseIndex::Coordination::PipelineLock#release"]
  CodebaseIndex__Coordination__PipelineLock_release -->|method_call| FileUtils
  CodebaseIndex__Coordination__PipelineLock_with_lock["CodebaseIndex::Coordination::PipelineLock#with_lock"]
  CodebaseIndex__Coordination__PipelineLock_locked_["CodebaseIndex::Coordination::PipelineLock#locked?"]
  CodebaseIndex__Coordination__PipelineLock_locked_ -->|method_call| File
  CodebaseIndex__Coordination__PipelineLock_stale_["CodebaseIndex::Coordination::PipelineLock#stale?"]
  CodebaseIndex__Coordination__PipelineLock_stale_ -->|method_call| File
  CodebaseIndex__Coordination__PipelineLock_stale_ -->|method_call| Time_now
  CodebaseIndex__Coordination__PipelineLock_stale_ -->|method_call| Time
  CodebaseIndex__Coordination__PipelineLock_lock_content["CodebaseIndex::Coordination::PipelineLock#lock_content"]
  CodebaseIndex__Coordination__PipelineLock_lock_content -->|method_call| JSON
  CodebaseIndex__CostModel["CodebaseIndex::CostModel"]
  CodebaseIndex__CostModel__EmbeddingCost["CodebaseIndex::CostModel::EmbeddingCost"]
  CodebaseIndex__CostModel__EmbeddingCost_initialize["CodebaseIndex::CostModel::EmbeddingCost#initialize"]
  ProviderPricing["ProviderPricing"]
  CodebaseIndex__CostModel__EmbeddingCost_initialize -->|method_call| ProviderPricing
  CodebaseIndex__CostModel__EmbeddingCost_full_index_cost["CodebaseIndex::CostModel::EmbeddingCost#full_index_cost"]
  CodebaseIndex__CostModel__EmbeddingCost_incremental_cost["CodebaseIndex::CostModel::EmbeddingCost#incremental_cost"]
  CodebaseIndex__CostModel__EmbeddingCost_monthly_query_cost["CodebaseIndex::CostModel::EmbeddingCost#monthly_query_cost"]
  CodebaseIndex__CostModel__EmbeddingCost_yearly_incremental_cost["CodebaseIndex::CostModel::EmbeddingCost#yearly_incremental_cost"]
  CodebaseIndex__CostModel__EmbeddingCost_total_tokens["CodebaseIndex::CostModel::EmbeddingCost#total_tokens"]
  CodebaseIndex__CostModel__EmbeddingCost_token_cost["CodebaseIndex::CostModel::EmbeddingCost#token_cost"]
  CodebaseIndex__CostModel__Estimator["CodebaseIndex::CostModel::Estimator"]
  CodebaseIndex__CostModel__Estimator_initialize["CodebaseIndex::CostModel::Estimator#initialize"]
  CodebaseIndex__CostModel__Estimator_initialize -->|method_call| ProviderPricing
  EmbeddingCost["EmbeddingCost"]
  CodebaseIndex__CostModel__Estimator_initialize -->|method_call| EmbeddingCost
  StorageCost["StorageCost"]
  CodebaseIndex__CostModel__Estimator_initialize -->|method_call| StorageCost
  CodebaseIndex__CostModel__Estimator_full_index_cost["CodebaseIndex::CostModel::Estimator#full_index_cost"]
  CodebaseIndex__CostModel__Estimator_incremental_per_merge_cost["CodebaseIndex::CostModel::Estimator#incremental_per_merge_cost"]
  CodebaseIndex__CostModel__Estimator_monthly_query_cost["CodebaseIndex::CostModel::Estimator#monthly_query_cost"]
  CodebaseIndex__CostModel__Estimator_yearly_incremental_cost["CodebaseIndex::CostModel::Estimator#yearly_incremental_cost"]
  CodebaseIndex__CostModel__Estimator_total_chunks["CodebaseIndex::CostModel::Estimator#total_chunks"]
  CodebaseIndex__CostModel__Estimator_storage_bytes["CodebaseIndex::CostModel::Estimator#storage_bytes"]
  CodebaseIndex__CostModel__Estimator_storage_mb["CodebaseIndex::CostModel::Estimator#storage_mb"]
  CodebaseIndex__CostModel__Estimator_to_h["CodebaseIndex::CostModel::Estimator#to_h"]
  CodebaseIndex__CostModel__ProviderPricing["CodebaseIndex::CostModel::ProviderPricing"]
  CodebaseIndex__CostModel__ProviderPricing_cost_per_million["CodebaseIndex::CostModel::ProviderPricing.cost_per_million"]
  COSTS_PER_MILLION_TOKENS["COSTS_PER_MILLION_TOKENS"]
  CodebaseIndex__CostModel__ProviderPricing_cost_per_million -->|method_call| COSTS_PER_MILLION_TOKENS
  CodebaseIndex__CostModel__ProviderPricing_default_dimensions["CodebaseIndex::CostModel::ProviderPricing.default_dimensions"]
  DEFAULT_DIMENSIONS["DEFAULT_DIMENSIONS"]
  CodebaseIndex__CostModel__ProviderPricing_default_dimensions -->|method_call| DEFAULT_DIMENSIONS
  CodebaseIndex__CostModel__ProviderPricing_providers["CodebaseIndex::CostModel::ProviderPricing.providers"]
  CodebaseIndex__CostModel__ProviderPricing_providers -->|method_call| COSTS_PER_MILLION_TOKENS
  CodebaseIndex__CostModel__StorageCost["CodebaseIndex::CostModel::StorageCost"]
  CodebaseIndex__CostModel__StorageCost_initialize["CodebaseIndex::CostModel::StorageCost#initialize"]
  CodebaseIndex__CostModel__StorageCost_bytes_per_vector["CodebaseIndex::CostModel::StorageCost#bytes_per_vector"]
  CodebaseIndex__CostModel__StorageCost_storage_bytes["CodebaseIndex::CostModel::StorageCost#storage_bytes"]
  CodebaseIndex__CostModel__StorageCost_storage_mb["CodebaseIndex::CostModel::StorageCost#storage_mb"]
  CodebaseIndex__Db["CodebaseIndex::Db"]
  CodebaseIndex__Db__Migrations["CodebaseIndex::Db::Migrations"]
  CodebaseIndex__Db__Migrations__CreateUnits["CodebaseIndex::Db::Migrations::CreateUnits"]
  CodebaseIndex__Db__Migrations__CreateUnits_up["CodebaseIndex::Db::Migrations::CreateUnits.up"]
  CodebaseIndex__Db__Migrations__CreateEdges["CodebaseIndex::Db::Migrations::CreateEdges"]
  CodebaseIndex__Db__Migrations__CreateEdges_up["CodebaseIndex::Db::Migrations::CreateEdges.up"]
  CodebaseIndex__Db__Migrations__CreateEmbeddings["CodebaseIndex::Db::Migrations::CreateEmbeddings"]
  CodebaseIndex__Db__Migrations__CreateEmbeddings_up["CodebaseIndex::Db::Migrations::CreateEmbeddings.up"]
  CodebaseIndex__Db__Migrations__CreateSnapshots["CodebaseIndex::Db::Migrations::CreateSnapshots"]
  CodebaseIndex__Db__Migrations__CreateSnapshots_up["CodebaseIndex::Db::Migrations::CreateSnapshots.up"]
  CodebaseIndex__Db__Migrations__CreateSnapshotUnits["CodebaseIndex::Db::Migrations::CreateSnapshotUnits"]
  CodebaseIndex__Db__Migrations__CreateSnapshotUnits_up["CodebaseIndex::Db::Migrations::CreateSnapshotUnits.up"]
  CodebaseIndex__Db__Migrator["CodebaseIndex::Db::Migrator"]
  CodebaseIndex__Db__Migrator_initialize["CodebaseIndex::Db::Migrator#initialize"]
  SchemaVersion["SchemaVersion"]
  CodebaseIndex__Db__Migrator_initialize -->|method_call| SchemaVersion
  CodebaseIndex__Db__Migrator_migrate_["CodebaseIndex::Db::Migrator#migrate!"]
  CodebaseIndex__Db__Migrator_pending_versions["CodebaseIndex::Db::Migrator#pending_versions"]
  MIGRATIONS_map["MIGRATIONS.map"]
  CodebaseIndex__Db__Migrator_pending_versions -->|method_call| MIGRATIONS_map
  CodebaseIndex__Db__Migrator_pending_migrations["CodebaseIndex::Db::Migrator#pending_migrations"]
  MIGRATIONS["MIGRATIONS"]
  CodebaseIndex__Db__Migrator_pending_migrations -->|method_call| MIGRATIONS
  CodebaseIndex__Db__SchemaVersion["CodebaseIndex::Db::SchemaVersion"]
  CodebaseIndex__Db__SchemaVersion_initialize["CodebaseIndex::Db::SchemaVersion#initialize"]
  CodebaseIndex__Db__SchemaVersion_ensure_table_["CodebaseIndex::Db::SchemaVersion#ensure_table!"]
  CodebaseIndex__Db__SchemaVersion_applied_versions["CodebaseIndex::Db::SchemaVersion#applied_versions"]
  CodebaseIndex__Db__SchemaVersion_record_version["CodebaseIndex::Db::SchemaVersion#record_version"]
  CodebaseIndex__Db__SchemaVersion_applied_["CodebaseIndex::Db::SchemaVersion#applied?"]
  CodebaseIndex__Db__SchemaVersion_current_version["CodebaseIndex::Db::SchemaVersion#current_version"]
  CodebaseIndex__DependencyGraph["CodebaseIndex::DependencyGraph"]
  CodebaseIndex__DependencyGraph_initialize["CodebaseIndex::DependencyGraph#initialize"]
  CodebaseIndex__DependencyGraph_register["CodebaseIndex::DependencyGraph#register"]
  CodebaseIndex__DependencyGraph_affected_by["CodebaseIndex::DependencyGraph#affected_by"]
  CodebaseIndex__DependencyGraph_affected_by -->|method_call| Set
  CodebaseIndex__DependencyGraph_dependencies_of["CodebaseIndex::DependencyGraph#dependencies_of"]
  CodebaseIndex__DependencyGraph_dependents_of["CodebaseIndex::DependencyGraph#dependents_of"]
  CodebaseIndex__DependencyGraph_units_of_type["CodebaseIndex::DependencyGraph#units_of_type"]
  CodebaseIndex__DependencyGraph_pagerank["CodebaseIndex::DependencyGraph#pagerank"]
  CodebaseIndex__DependencyGraph_to_h["CodebaseIndex::DependencyGraph#to_h"]
  CodebaseIndex__DependencyGraph_from_h["CodebaseIndex::DependencyGraph.from_h"]
  CodebaseIndex__DependencyGraph_symbolize_node["CodebaseIndex::DependencyGraph.symbolize_node"]
  CodebaseIndex__Embedding["CodebaseIndex::Embedding"]
  CodebaseIndex__Embedding__Indexer["CodebaseIndex::Embedding::Indexer"]
  CodebaseIndex__Embedding__Indexer_initialize["CodebaseIndex::Embedding::Indexer#initialize"]
  CodebaseIndex__Embedding__Indexer_index_all["CodebaseIndex::Embedding::Indexer#index_all"]
  CodebaseIndex__Embedding__Indexer_index_incremental["CodebaseIndex::Embedding::Indexer#index_incremental"]
  CodebaseIndex__Embedding__Indexer_load_units["CodebaseIndex::Embedding::Indexer#load_units"]
  Dir_glob["Dir.glob"]
  CodebaseIndex__Embedding__Indexer_load_units -->|method_call| Dir_glob
  File_basename["File.basename"]
  CodebaseIndex__Embedding__Indexer_load_units -->|method_call| File_basename
  CodebaseIndex__Embedding__Indexer_load_units -->|method_call| File
  CodebaseIndex__Embedding__Indexer_load_units -->|method_call| JSON
  CodebaseIndex__Embedding__Indexer_process_units["CodebaseIndex::Embedding::Indexer#process_units"]
  CodebaseIndex__Embedding__Indexer_process_batch["CodebaseIndex::Embedding::Indexer#process_batch"]
  CodebaseIndex__Embedding__Indexer_collect_embed_items["CodebaseIndex::Embedding::Indexer#collect_embed_items"]
  CodebaseIndex__Embedding__Indexer_prepare_texts["CodebaseIndex::Embedding::Indexer#prepare_texts"]
  CodebaseIndex__Embedding__Indexer_build_unit["CodebaseIndex::Embedding::Indexer#build_unit"]
  ExtractedUnit["ExtractedUnit"]
  CodebaseIndex__Embedding__Indexer_build_unit -->|method_call| ExtractedUnit
  CodebaseIndex__Embedding__Indexer_embed_and_store["CodebaseIndex::Embedding::Indexer#embed_and_store"]
  CodebaseIndex__Embedding__Indexer_store_vectors["CodebaseIndex::Embedding::Indexer#store_vectors"]
  CodebaseIndex__Embedding__Indexer_load_checkpoint["CodebaseIndex::Embedding::Indexer#load_checkpoint"]
  CodebaseIndex__Embedding__Indexer_load_checkpoint -->|method_call| File
  CodebaseIndex__Embedding__Indexer_load_checkpoint -->|method_call| JSON
  CodebaseIndex__Embedding__Indexer_save_checkpoint["CodebaseIndex::Embedding::Indexer#save_checkpoint"]
  CodebaseIndex__Embedding__Indexer_save_checkpoint -->|method_call| File
  CodebaseIndex__Embedding__Provider["CodebaseIndex::Embedding::Provider"]
  CodebaseIndex__Embedding__Provider__OpenAI["CodebaseIndex::Embedding::Provider::OpenAI"]
  Interface["Interface"]
  CodebaseIndex__Embedding__Provider__OpenAI -->|include| Interface
  CodebaseIndex__Embedding__Provider__OpenAI_initialize["CodebaseIndex::Embedding::Provider::OpenAI#initialize"]
  CodebaseIndex__Embedding__Provider__OpenAI_embed["CodebaseIndex::Embedding::Provider::OpenAI#embed"]
  CodebaseIndex__Embedding__Provider__OpenAI_embed_batch["CodebaseIndex::Embedding::Provider::OpenAI#embed_batch"]
  CodebaseIndex__Embedding__Provider__OpenAI_dimensions["CodebaseIndex::Embedding::Provider::OpenAI#dimensions"]
  DIMENSIONS["DIMENSIONS"]
  CodebaseIndex__Embedding__Provider__OpenAI_dimensions -->|method_call| DIMENSIONS
  CodebaseIndex__Embedding__Provider__OpenAI_model_name["CodebaseIndex::Embedding::Provider::OpenAI#model_name"]
  CodebaseIndex__Embedding__Provider__OpenAI_post_request["CodebaseIndex::Embedding::Provider::OpenAI#post_request"]
  Net__HTTP["Net::HTTP"]
  CodebaseIndex__Embedding__Provider__OpenAI_post_request -->|method_call| Net__HTTP
  Net__HTTP__Post["Net::HTTP::Post"]
  CodebaseIndex__Embedding__Provider__OpenAI_post_request -->|method_call| Net__HTTP__Post
  CodebaseIndex__Embedding__Provider__OpenAI_post_request -->|method_call| JSON
  CodebaseIndex__Embedding__Provider__Interface["CodebaseIndex::Embedding::Provider::Interface"]
  CodebaseIndex__Embedding__Provider__Ollama["CodebaseIndex::Embedding::Provider::Ollama"]
  CodebaseIndex__Embedding__Provider__Ollama -->|include| Interface
  CodebaseIndex__Embedding__Provider__Interface_embed["CodebaseIndex::Embedding::Provider::Interface#embed"]
  CodebaseIndex__Embedding__Provider__Interface_embed_batch["CodebaseIndex::Embedding::Provider::Interface#embed_batch"]
  CodebaseIndex__Embedding__Provider__Interface_dimensions["CodebaseIndex::Embedding::Provider::Interface#dimensions"]
  CodebaseIndex__Embedding__Provider__Interface_model_name["CodebaseIndex::Embedding::Provider::Interface#model_name"]
  CodebaseIndex__Embedding__Provider__Ollama_initialize["CodebaseIndex::Embedding::Provider::Ollama#initialize"]
  CodebaseIndex__Embedding__Provider__Ollama_embed["CodebaseIndex::Embedding::Provider::Ollama#embed"]
  CodebaseIndex__Embedding__Provider__Ollama_embed_batch["CodebaseIndex::Embedding::Provider::Ollama#embed_batch"]
  CodebaseIndex__Embedding__Provider__Ollama_dimensions["CodebaseIndex::Embedding::Provider::Ollama#dimensions"]
  CodebaseIndex__Embedding__Provider__Ollama_model_name["CodebaseIndex::Embedding::Provider::Ollama#model_name"]
  CodebaseIndex__Embedding__Provider__Ollama_post_request["CodebaseIndex::Embedding::Provider::Ollama#post_request"]
  CodebaseIndex__Embedding__Provider__Ollama_post_request -->|method_call| Net__HTTP
  CodebaseIndex__Embedding__Provider__Ollama_post_request -->|method_call| Net__HTTP__Post
  CodebaseIndex__Embedding__Provider__Ollama_post_request -->|method_call| JSON
  CodebaseIndex__Embedding__TextPreparer["CodebaseIndex::Embedding::TextPreparer"]
  CodebaseIndex__Embedding__TextPreparer_initialize["CodebaseIndex::Embedding::TextPreparer#initialize"]
  CodebaseIndex__Embedding__TextPreparer_prepare["CodebaseIndex::Embedding::TextPreparer#prepare"]
  CodebaseIndex__Embedding__TextPreparer_prepare_chunks["CodebaseIndex::Embedding::TextPreparer#prepare_chunks"]
  CodebaseIndex__Embedding__TextPreparer_build_prefix["CodebaseIndex::Embedding::TextPreparer#build_prefix"]
  CodebaseIndex__Embedding__TextPreparer_append_dependency_line["CodebaseIndex::Embedding::TextPreparer#append_dependency_line"]
  CodebaseIndex__Embedding__TextPreparer_select_content["CodebaseIndex::Embedding::TextPreparer#select_content"]
  CodebaseIndex__Embedding__TextPreparer_enforce_token_limit["CodebaseIndex::Embedding::TextPreparer#enforce_token_limit"]
  CodebaseIndex__Evaluation["CodebaseIndex::Evaluation"]
  CodebaseIndex__Evaluation__BaselineRunner["CodebaseIndex::Evaluation::BaselineRunner"]
  CodebaseIndex__Evaluation__BaselineRunner_initialize["CodebaseIndex::Evaluation::BaselineRunner#initialize"]
  CodebaseIndex__Evaluation__BaselineRunner_run["CodebaseIndex::Evaluation::BaselineRunner#run"]
  VALID_STRATEGIES["VALID_STRATEGIES"]
  CodebaseIndex__Evaluation__BaselineRunner_run -->|method_call| VALID_STRATEGIES
  CodebaseIndex__Evaluation__BaselineRunner_run_grep["CodebaseIndex::Evaluation::BaselineRunner#run_grep"]
  CodebaseIndex__Evaluation__BaselineRunner_run_random["CodebaseIndex::Evaluation::BaselineRunner#run_random"]
  CodebaseIndex__Evaluation__BaselineRunner_run_file_level["CodebaseIndex::Evaluation::BaselineRunner#run_file_level"]
  CodebaseIndex__Evaluation__BaselineRunner_extract_keywords["CodebaseIndex::Evaluation::BaselineRunner#extract_keywords"]
  CodebaseIndex__Evaluation__Evaluator["CodebaseIndex::Evaluation::Evaluator"]
  CodebaseIndex__Evaluation__Evaluator_initialize["CodebaseIndex::Evaluation::Evaluator#initialize"]
  CodebaseIndex__Evaluation__Evaluator_evaluate["CodebaseIndex::Evaluation::Evaluator#evaluate"]
  EvaluationReport["EvaluationReport"]
  CodebaseIndex__Evaluation__Evaluator_evaluate -->|method_call| EvaluationReport
  CodebaseIndex__Evaluation__Evaluator_evaluate_query["CodebaseIndex::Evaluation::Evaluator#evaluate_query"]
  QueryResult["QueryResult"]
  CodebaseIndex__Evaluation__Evaluator_evaluate_query -->|method_call| QueryResult
  CodebaseIndex__Evaluation__Evaluator_extract_identifiers["CodebaseIndex::Evaluation::Evaluator#extract_identifiers"]
  CodebaseIndex__Evaluation__Evaluator_compute_scores["CodebaseIndex::Evaluation::Evaluator#compute_scores"]
  CodebaseIndex__Evaluation__Evaluator_compute_token_efficiency["CodebaseIndex::Evaluation::Evaluator#compute_token_efficiency"]
  Metrics["Metrics"]
  CodebaseIndex__Evaluation__Evaluator_compute_token_efficiency -->|method_call| Metrics
  CodebaseIndex__Evaluation__Evaluator_compute_aggregates["CodebaseIndex::Evaluation::Evaluator#compute_aggregates"]
  CodebaseIndex__Evaluation__Evaluator_empty_aggregates["CodebaseIndex::Evaluation::Evaluator#empty_aggregates"]
  CodebaseIndex__Evaluation__Metrics["CodebaseIndex::Evaluation::Metrics"]
  CodebaseIndex__Evaluation__Metrics_precision_at_k["CodebaseIndex::Evaluation::Metrics#precision_at_k"]
  CodebaseIndex__Evaluation__Metrics_recall["CodebaseIndex::Evaluation::Metrics#recall"]
  CodebaseIndex__Evaluation__Metrics_mrr["CodebaseIndex::Evaluation::Metrics#mrr"]
  CodebaseIndex__Evaluation__Metrics_context_completeness["CodebaseIndex::Evaluation::Metrics#context_completeness"]
  CodebaseIndex__Evaluation__Metrics_token_efficiency["CodebaseIndex::Evaluation::Metrics#token_efficiency"]
  CodebaseIndex__Evaluation__QuerySet["CodebaseIndex::Evaluation::QuerySet"]
  CodebaseIndex__Evaluation__QuerySet_initialize["CodebaseIndex::Evaluation::QuerySet#initialize"]
  CodebaseIndex__Evaluation__QuerySet_load["CodebaseIndex::Evaluation::QuerySet.load"]
  CodebaseIndex__Evaluation__QuerySet_load -->|method_call| JSON
  CodebaseIndex__Evaluation__QuerySet_save["CodebaseIndex::Evaluation::QuerySet#save"]
  CodebaseIndex__Evaluation__QuerySet_save -->|method_call| File
  CodebaseIndex__Evaluation__QuerySet_filter["CodebaseIndex::Evaluation::QuerySet#filter"]
  CodebaseIndex__Evaluation__QuerySet_add["CodebaseIndex::Evaluation::QuerySet#add"]
  CodebaseIndex__Evaluation__QuerySet_size["CodebaseIndex::Evaluation::QuerySet#size"]
  CodebaseIndex__Evaluation__QuerySet_parse_query["CodebaseIndex::Evaluation::QuerySet.parse_query"]
  Query["Query"]
  CodebaseIndex__Evaluation__QuerySet_parse_query -->|method_call| Query
  CodebaseIndex__Evaluation__QuerySet_serialize_query["CodebaseIndex::Evaluation::QuerySet#serialize_query"]
  CodebaseIndex__Evaluation__QuerySet_validate_query_["CodebaseIndex::Evaluation::QuerySet#validate_query!"]
  VALID_INTENTS["VALID_INTENTS"]
  CodebaseIndex__Evaluation__QuerySet_validate_query_ -->|method_call| VALID_INTENTS
  VALID_SCOPES["VALID_SCOPES"]
  CodebaseIndex__Evaluation__QuerySet_validate_query_ -->|method_call| VALID_SCOPES
  CodebaseIndex__Evaluation__ReportGenerator["CodebaseIndex::Evaluation::ReportGenerator"]
  CodebaseIndex__Evaluation__ReportGenerator_generate["CodebaseIndex::Evaluation::ReportGenerator#generate"]
  CodebaseIndex__Evaluation__ReportGenerator_generate -->|method_call| JSON
  CodebaseIndex__Evaluation__ReportGenerator_save["CodebaseIndex::Evaluation::ReportGenerator#save"]
  CodebaseIndex__Evaluation__ReportGenerator_save -->|method_call| FileUtils
  CodebaseIndex__Evaluation__ReportGenerator_save -->|method_call| File
  CodebaseIndex__Evaluation__ReportGenerator_build_report_hash["CodebaseIndex::Evaluation::ReportGenerator#build_report_hash"]
  CodebaseIndex__Evaluation__ReportGenerator_build_metadata["CodebaseIndex::Evaluation::ReportGenerator#build_metadata"]
  CodebaseIndex__Evaluation__ReportGenerator_serialize_aggregates["CodebaseIndex::Evaluation::ReportGenerator#serialize_aggregates"]
  CodebaseIndex__Evaluation__ReportGenerator_serialize_result["CodebaseIndex::Evaluation::ReportGenerator#serialize_result"]
  CodebaseIndex__ExtractedUnit["CodebaseIndex::ExtractedUnit"]
  CodebaseIndex__ExtractedUnit_initialize["CodebaseIndex::ExtractedUnit#initialize"]
  CodebaseIndex__ExtractedUnit_to_h["CodebaseIndex::ExtractedUnit#to_h"]
  CodebaseIndex__ExtractedUnit_estimated_tokens["CodebaseIndex::ExtractedUnit#estimated_tokens"]
  CodebaseIndex__ExtractedUnit_needs_chunking_["CodebaseIndex::ExtractedUnit#needs_chunking?"]
  CodebaseIndex__ExtractedUnit_build_default_chunks["CodebaseIndex::ExtractedUnit#build_default_chunks"]
  CodebaseIndex__ExtractedUnit_build_chunk_header["CodebaseIndex::ExtractedUnit#build_chunk_header"]
  CodebaseIndex__Extractor["CodebaseIndex::Extractor"]
  CodebaseIndex__Extractor_initialize["CodebaseIndex::Extractor#initialize"]
  Pathname["Pathname"]
  CodebaseIndex__Extractor_initialize -->|method_call| Pathname
  DependencyGraph["DependencyGraph"]
  CodebaseIndex__Extractor_initialize -->|method_call| DependencyGraph
  CodebaseIndex__Extractor_extract_all["CodebaseIndex::Extractor#extract_all"]
  ModelNameCache["ModelNameCache"]
  CodebaseIndex__Extractor_extract_all -->|method_call| ModelNameCache
  CodebaseIndex_configuration["CodebaseIndex.configuration"]
  CodebaseIndex__Extractor_extract_all -->|method_call| CodebaseIndex_configuration
  CodebaseIndex__Extractor_extract_all -->|method_call| CodebaseIndex
  Rails_logger["Rails.logger"]
  CodebaseIndex__Extractor_extract_all -->|method_call| Rails_logger
  CodebaseIndex__Extractor_extract_all -->|method_call| Rails
  GraphAnalyzer_new["GraphAnalyzer.new"]
  CodebaseIndex__Extractor_extract_all -->|method_call| GraphAnalyzer_new
  GraphAnalyzer["GraphAnalyzer"]
  CodebaseIndex__Extractor_extract_all -->|method_call| GraphAnalyzer
  CodebaseIndex__Extractor_extract_changed["CodebaseIndex::Extractor#extract_changed"]
  CodebaseIndex__Extractor_extract_changed -->|method_call| DependencyGraph
  CodebaseIndex__Extractor_extract_changed -->|method_call| ModelNameCache
  Pathname_new["Pathname.new"]
  CodebaseIndex__Extractor_extract_changed -->|method_call| Pathname_new
  CodebaseIndex__Extractor_extract_changed -->|method_call| Pathname
  Rails_root_join["Rails.root.join"]
  CodebaseIndex__Extractor_extract_changed -->|method_call| Rails_root_join
  Rails_root["Rails.root"]
  CodebaseIndex__Extractor_extract_changed -->|method_call| Rails_root
  CodebaseIndex__Extractor_extract_changed -->|method_call| Rails
  CodebaseIndex__Extractor_extract_changed -->|method_call| Rails_logger
  CodebaseIndex__Extractor_extract_changed -->|method_call| Set
  CodebaseIndex__Extractor_safe_eager_load_["CodebaseIndex::Extractor#safe_eager_load!"]
  Rails_application["Rails.application"]
  CodebaseIndex__Extractor_safe_eager_load_ -->|method_call| Rails_application
  CodebaseIndex__Extractor_safe_eager_load_ -->|method_call| Rails
  CodebaseIndex__Extractor_safe_eager_load_ -->|method_call| Rails_logger
  CodebaseIndex__Extractor_eager_load_extraction_directories["CodebaseIndex::Extractor#eager_load_extraction_directories"]
  Rails_autoloaders["Rails.autoloaders"]
  CodebaseIndex__Extractor_eager_load_extraction_directories -->|method_call| Rails_autoloaders
  CodebaseIndex__Extractor_eager_load_extraction_directories -->|method_call| Rails
  EXTRACTION_DIRECTORIES["EXTRACTION_DIRECTORIES"]
  CodebaseIndex__Extractor_eager_load_extraction_directories -->|method_call| EXTRACTION_DIRECTORIES
  CodebaseIndex__Extractor_eager_load_extraction_directories -->|method_call| Rails_root
  CodebaseIndex__Extractor_eager_load_extraction_directories -->|method_call| Dir_glob
  CodebaseIndex__Extractor_eager_load_extraction_directories -->|method_call| Rails_logger
  CodebaseIndex__Extractor_extract_all_sequential["CodebaseIndex::Extractor#extract_all_sequential"]
  EXTRACTORS["EXTRACTORS"]
  CodebaseIndex__Extractor_extract_all_sequential -->|method_call| EXTRACTORS
  CodebaseIndex__Extractor_extract_all_sequential -->|method_call| Rails_logger
  CodebaseIndex__Extractor_extract_all_sequential -->|method_call| Rails
  CodebaseIndex__Extractor_extract_all_sequential -->|method_call| Time
  Time_current["Time.current"]
  CodebaseIndex__Extractor_extract_all_sequential -->|method_call| Time_current
  CodebaseIndex__Extractor_extract_all_concurrent["CodebaseIndex::Extractor#extract_all_concurrent"]
  CodebaseIndex__Extractor_extract_all_concurrent -->|method_call| ModelNameCache
  Mutex["Mutex"]
  CodebaseIndex__Extractor_extract_all_concurrent -->|method_call| Mutex
  CodebaseIndex__Extractor_extract_all_concurrent -->|method_call| EXTRACTORS
  Thread["Thread"]
  CodebaseIndex__Extractor_extract_all_concurrent -->|method_call| Thread
  CodebaseIndex__Extractor_extract_all_concurrent -->|method_call| Rails_logger
  CodebaseIndex__Extractor_extract_all_concurrent -->|method_call| Rails
  CodebaseIndex__Extractor_extract_all_concurrent -->|method_call| Time
  CodebaseIndex__Extractor_extract_all_concurrent -->|method_call| Time_current
  CodebaseIndex__Extractor_setup_output_directory["CodebaseIndex::Extractor#setup_output_directory"]
  CodebaseIndex__Extractor_setup_output_directory -->|method_call| FileUtils
  CodebaseIndex__Extractor_setup_output_directory -->|method_call| EXTRACTORS
  CodebaseIndex__Extractor_resolve_dependents["CodebaseIndex::Extractor#resolve_dependents"]
  CodebaseIndex__Extractor_precompute_flows["CodebaseIndex::Extractor#precompute_flows"]
  FlowPrecomputer["FlowPrecomputer"]
  CodebaseIndex__Extractor_precompute_flows -->|method_call| FlowPrecomputer
  CodebaseIndex__Extractor_precompute_flows -->|method_call| Rails_logger
  CodebaseIndex__Extractor_precompute_flows -->|method_call| Rails
  CodebaseIndex__Extractor_enrich_with_git_data["CodebaseIndex::Extractor#enrich_with_git_data"]
  CodebaseIndex__Extractor_enrich_with_git_data -->|method_call| File
  CodebaseIndex__Extractor_git_available_["CodebaseIndex::Extractor#git_available?"]
  CodebaseIndex__Extractor_git_available_ -->|method_call| Open3
  CodebaseIndex__Extractor_run_git["CodebaseIndex::Extractor#run_git"]
  CodebaseIndex__Extractor_run_git -->|method_call| Open3
  CodebaseIndex__Extractor_batch_git_data["CodebaseIndex::Extractor#batch_git_data"]
  CodebaseIndex__Extractor_batch_git_data -->|method_call| Time_current
  CodebaseIndex__Extractor_batch_git_data -->|method_call| Time
  CodebaseIndex__Extractor_parse_git_log_output["CodebaseIndex::Extractor#parse_git_log_output"]
  Hash["Hash"]
  CodebaseIndex__Extractor_parse_git_log_output -->|method_call| Hash
  CodebaseIndex__Extractor_classify_change_frequency["CodebaseIndex::Extractor#classify_change_frequency"]
  CodebaseIndex__Extractor_build_file_metadata["CodebaseIndex::Extractor#build_file_metadata"]
  CodebaseIndex__Extractor_write_results["CodebaseIndex::Extractor#write_results"]
  CodebaseIndex__Extractor_write_results -->|method_call| File
  CodebaseIndex__Extractor_write_dependency_graph["CodebaseIndex::Extractor#write_dependency_graph"]
  CodebaseIndex__Extractor_write_dependency_graph -->|method_call| File
  CodebaseIndex__Extractor_write_graph_analysis["CodebaseIndex::Extractor#write_graph_analysis"]
  CodebaseIndex__Extractor_write_graph_analysis -->|method_call| File
  CodebaseIndex__Extractor_write_manifest["CodebaseIndex::Extractor#write_manifest"]
  CodebaseIndex__Extractor_write_manifest -->|method_call| File
  CodebaseIndex__Extractor_write_structural_summary["CodebaseIndex::Extractor#write_structural_summary"]
  CodebaseIndex__Extractor_write_structural_summary -->|method_call| File
  CodebaseIndex__Extractor_regenerate_type_index["CodebaseIndex::Extractor#regenerate_type_index"]
  Dir___["Dir.[]"]
  CodebaseIndex__Extractor_regenerate_type_index -->|method_call| Dir___
  CodebaseIndex__Extractor_regenerate_type_index -->|method_call| File_basename
  CodebaseIndex__Extractor_regenerate_type_index -->|method_call| File
  CodebaseIndex__Extractor_regenerate_type_index -->|method_call| JSON
  CodebaseIndex__Extractor_gemfile_lock_sha["CodebaseIndex::Extractor#gemfile_lock_sha"]
  CodebaseIndex__Extractor_gemfile_lock_sha -->|method_call| Rails_root
  CodebaseIndex__Extractor_gemfile_lock_sha -->|method_call| Rails
  Digest__SHA256_file["Digest::SHA256.file"]
  CodebaseIndex__Extractor_gemfile_lock_sha -->|method_call| Digest__SHA256_file
  CodebaseIndex__Extractor_gemfile_lock_sha -->|method_call| Digest__SHA256
  CodebaseIndex__Extractor_schema_sha["CodebaseIndex::Extractor#schema_sha"]
  CodebaseIndex__Extractor_schema_sha -->|method_call| Rails_root
  CodebaseIndex__Extractor_schema_sha -->|method_call| Rails
  CodebaseIndex__Extractor_schema_sha -->|method_call| Digest__SHA256_file
  CodebaseIndex__Extractor_schema_sha -->|method_call| Digest__SHA256
  CodebaseIndex__Extractor_safe_filename["CodebaseIndex::Extractor#safe_filename"]
  CodebaseIndex__Extractor_json_serialize["CodebaseIndex::Extractor#json_serialize"]
  CodebaseIndex__Extractor_json_serialize -->|method_call| CodebaseIndex_configuration
  CodebaseIndex__Extractor_json_serialize -->|method_call| CodebaseIndex
  CodebaseIndex__Extractor_json_serialize -->|method_call| JSON
  CodebaseIndex__Extractor_log_summary["CodebaseIndex::Extractor#log_summary"]
  CodebaseIndex__Extractor_log_summary -->|method_call| Rails_logger
  CodebaseIndex__Extractor_log_summary -->|method_call| Rails
  CodebaseIndex__Extractor_re_extract_unit["CodebaseIndex::Extractor#re_extract_unit"]
  CodebaseIndex__Extractor_re_extract_unit -->|method_call| Rails_logger
  CodebaseIndex__Extractor_re_extract_unit -->|method_call| Rails
  CodebaseIndex__Extractor_re_extract_unit -->|method_call| File
  TYPE_TO_EXTRACTOR_KEY["TYPE_TO_EXTRACTOR_KEY"]
  CodebaseIndex__Extractor_re_extract_unit -->|method_call| TYPE_TO_EXTRACTOR_KEY
  EXTRACTORS___["EXTRACTORS.[]"]
  CodebaseIndex__Extractor_re_extract_unit -->|method_call| EXTRACTORS___
  CodebaseIndex__Extractor_re_extract_unit -->|method_call| EXTRACTORS
  CLASS_BASED["CLASS_BASED"]
  CodebaseIndex__Extractor_re_extract_unit -->|method_call| CLASS_BASED
  FILE_BASED["FILE_BASED"]
  CodebaseIndex__Extractor_re_extract_unit -->|method_call| FILE_BASED
  GRAPHQL_TYPES["GRAPHQL_TYPES"]
  CodebaseIndex__Extractor_re_extract_unit -->|method_call| GRAPHQL_TYPES
  CodebaseIndex__Extractors["CodebaseIndex::Extractors"]
  CodebaseIndex__Extractors__ActionCableExtractor["CodebaseIndex::Extractors::ActionCableExtractor"]
  SharedUtilityMethods["SharedUtilityMethods"]
  CodebaseIndex__Extractors__ActionCableExtractor -->|include| SharedUtilityMethods
  SharedDependencyScanner["SharedDependencyScanner"]
  CodebaseIndex__Extractors__ActionCableExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__ActionCableExtractor_initialize["CodebaseIndex::Extractors::ActionCableExtractor#initialize"]
  CodebaseIndex__Extractors__ActionCableExtractor_extract_all["CodebaseIndex::Extractors::ActionCableExtractor#extract_all"]
  CodebaseIndex__Extractors__ActionCableExtractor_extract_channel["CodebaseIndex::Extractors::ActionCableExtractor#extract_channel"]
  CodebaseIndex__Extractors__ActionCableExtractor_extract_channel -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__ActionCableExtractor_action_cable_available_["CodebaseIndex::Extractors::ActionCableExtractor#action_cable_available?"]
  CodebaseIndex__Extractors__ActionCableExtractor_channel_descendants["CodebaseIndex::Extractors::ActionCableExtractor#channel_descendants"]
  ActionCable__Channel__Base_descendants["ActionCable::Channel::Base.descendants"]
  CodebaseIndex__Extractors__ActionCableExtractor_channel_descendants -->|method_call| ActionCable__Channel__Base_descendants
  CodebaseIndex__Extractors__ActionCableExtractor_discover_source_path["CodebaseIndex::Extractors::ActionCableExtractor#discover_source_path"]
  CodebaseIndex__Extractors__ActionCableExtractor_source_location_from_methods["CodebaseIndex::Extractors::ActionCableExtractor#source_location_from_methods"]
  CodebaseIndex__Extractors__ActionCableExtractor_convention_fallback["CodebaseIndex::Extractors::ActionCableExtractor#convention_fallback"]
  CodebaseIndex__Extractors__ActionCableExtractor_convention_fallback -->|method_call| Rails
  CodebaseIndex__Extractors__ActionCableExtractor_convention_fallback -->|method_call| Rails_root_join
  CodebaseIndex__Extractors__ActionCableExtractor_convention_fallback -->|method_call| Rails_root
  CodebaseIndex__Extractors__ActionCableExtractor_convention_fallback -->|method_call| File
  CodebaseIndex__Extractors__ActionCableExtractor_read_source["CodebaseIndex::Extractors::ActionCableExtractor#read_source"]
  CodebaseIndex__Extractors__ActionCableExtractor_read_source -->|method_call| File
  CodebaseIndex__Extractors__ActionCableExtractor_build_metadata["CodebaseIndex::Extractors::ActionCableExtractor#build_metadata"]
  CodebaseIndex__Extractors__ActionCableExtractor_detect_stream_names["CodebaseIndex::Extractors::ActionCableExtractor#detect_stream_names"]
  CodebaseIndex__Extractors__ActionCableExtractor_detect_actions["CodebaseIndex::Extractors::ActionCableExtractor#detect_actions"]
  CodebaseIndex__Extractors__ActionCableExtractor_detect_broadcasts["CodebaseIndex::Extractors::ActionCableExtractor#detect_broadcasts"]
  CodebaseIndex__Extractors__ActionCableExtractor_count_loc["CodebaseIndex::Extractors::ActionCableExtractor#count_loc"]
  CodebaseIndex__Extractors__ActionCableExtractor_log_extraction_error["CodebaseIndex::Extractors::ActionCableExtractor#log_extraction_error"]
  CodebaseIndex__Extractors__ActionCableExtractor_log_extraction_error -->|method_call| Rails
  CodebaseIndex__Extractors__ActionCableExtractor_log_extraction_error -->|method_call| Rails_logger
  CodebaseIndex__Extractors__AstSourceExtraction["CodebaseIndex::Extractors::AstSourceExtraction"]
  CodebaseIndex__Extractors__AstSourceExtraction_extract_action_source["CodebaseIndex::Extractors::AstSourceExtraction#extract_action_source"]
  CodebaseIndex__Extractors__AstSourceExtraction_extract_action_source -->|method_call| File
  Ast__MethodExtractor_new["Ast::MethodExtractor.new"]
  CodebaseIndex__Extractors__AstSourceExtraction_extract_action_source -->|method_call| Ast__MethodExtractor_new
  Ast__MethodExtractor["Ast::MethodExtractor"]
  CodebaseIndex__Extractors__AstSourceExtraction_extract_action_source -->|method_call| Ast__MethodExtractor
  CodebaseIndex__Extractors__AstSourceExtraction_extract_action_source -->|method_call| Rails_logger
  CodebaseIndex__Extractors__AstSourceExtraction_extract_action_source -->|method_call| Rails
  CodebaseIndex__Extractors__BehavioralProfile["CodebaseIndex::Extractors::BehavioralProfile"]
  CodebaseIndex__Extractors__BehavioralProfile_extract["CodebaseIndex::Extractors::BehavioralProfile#extract"]
  CodebaseIndex__Extractors__BehavioralProfile_extract -->|method_call| Rails_application
  CodebaseIndex__Extractors__BehavioralProfile_extract -->|method_call| Rails
  CodebaseIndex__Extractors__BehavioralProfile_extract -->|method_call| Rails_logger
  CodebaseIndex__Extractors__BehavioralProfile_extract_database["CodebaseIndex::Extractors::BehavioralProfile#extract_database"]
  ActiveRecord__Base["ActiveRecord::Base"]
  CodebaseIndex__Extractors__BehavioralProfile_extract_database -->|method_call| ActiveRecord__Base
  CodebaseIndex__Extractors__BehavioralProfile_extract_database -->|method_call| Rails_logger
  CodebaseIndex__Extractors__BehavioralProfile_extract_database -->|method_call| Rails
  CodebaseIndex__Extractors__BehavioralProfile_extract_frameworks["CodebaseIndex::Extractors::BehavioralProfile#extract_frameworks"]
  FRAMEWORK_CHECKS["FRAMEWORK_CHECKS"]
  CodebaseIndex__Extractors__BehavioralProfile_extract_frameworks -->|method_call| FRAMEWORK_CHECKS
  Object["Object"]
  CodebaseIndex__Extractors__BehavioralProfile_extract_frameworks -->|method_call| Object
  CodebaseIndex__Extractors__BehavioralProfile_extract_frameworks -->|method_call| Rails_logger
  CodebaseIndex__Extractors__BehavioralProfile_extract_frameworks -->|method_call| Rails
  CodebaseIndex__Extractors__BehavioralProfile_extract_behavior_flags["CodebaseIndex::Extractors::BehavioralProfile#extract_behavior_flags"]
  CodebaseIndex__Extractors__BehavioralProfile_extract_behavior_flags -->|method_call| Rails_logger
  CodebaseIndex__Extractors__BehavioralProfile_extract_behavior_flags -->|method_call| Rails
  CodebaseIndex__Extractors__BehavioralProfile_extract_background["CodebaseIndex::Extractors::BehavioralProfile#extract_background"]
  CodebaseIndex__Extractors__BehavioralProfile_extract_background -->|method_call| Rails_logger
  CodebaseIndex__Extractors__BehavioralProfile_extract_background -->|method_call| Rails
  CodebaseIndex__Extractors__BehavioralProfile_extract_caching["CodebaseIndex::Extractors::BehavioralProfile#extract_caching"]
  CodebaseIndex__Extractors__BehavioralProfile_extract_caching -->|method_call| Rails_logger
  CodebaseIndex__Extractors__BehavioralProfile_extract_caching -->|method_call| Rails
  CodebaseIndex__Extractors__BehavioralProfile_extract_email["CodebaseIndex::Extractors::BehavioralProfile#extract_email"]
  CodebaseIndex__Extractors__BehavioralProfile_extract_email -->|method_call| Rails_logger
  CodebaseIndex__Extractors__BehavioralProfile_extract_email -->|method_call| Rails
  CodebaseIndex__Extractors__BehavioralProfile_build_unit["CodebaseIndex::Extractors::BehavioralProfile#build_unit"]
  CodebaseIndex__Extractors__BehavioralProfile_build_unit -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__BehavioralProfile_build_narrative["CodebaseIndex::Extractors::BehavioralProfile#build_narrative"]
  CodebaseIndex__Extractors__BehavioralProfile_build_dependencies["CodebaseIndex::Extractors::BehavioralProfile#build_dependencies"]
  CodebaseIndex__Extractors__BehavioralProfile_build_dependencies -->|method_call| FRAMEWORK_CHECKS
  CodebaseIndex__Extractors__BehavioralProfile_safe_read["CodebaseIndex::Extractors::BehavioralProfile#safe_read"]
  CodebaseIndex__Extractors__CachingExtractor["CodebaseIndex::Extractors::CachingExtractor"]
  CodebaseIndex__Extractors__CachingExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__CachingExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__CachingExtractor_initialize["CodebaseIndex::Extractors::CachingExtractor#initialize"]
  CodebaseIndex__Extractors__CachingExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__CachingExtractor_extract_all["CodebaseIndex::Extractors::CachingExtractor#extract_all"]
  SCAN_PATTERNS["SCAN_PATTERNS"]
  CodebaseIndex__Extractors__CachingExtractor_extract_all -->|method_call| SCAN_PATTERNS
  CodebaseIndex__Extractors__CachingExtractor_extract_all -->|method_call| Dir___
  CodebaseIndex__Extractors__CachingExtractor_extract_caching_file["CodebaseIndex::Extractors::CachingExtractor#extract_caching_file"]
  CodebaseIndex__Extractors__CachingExtractor_extract_caching_file -->|method_call| File
  CodebaseIndex__Extractors__CachingExtractor_extract_caching_file -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__CachingExtractor_extract_caching_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__CachingExtractor_extract_caching_file -->|method_call| Rails
  CodebaseIndex__Extractors__CachingExtractor_cache_usage_["CodebaseIndex::Extractors::CachingExtractor#cache_usage?"]
  CACHE_PATTERNS_values["CACHE_PATTERNS.values"]
  CodebaseIndex__Extractors__CachingExtractor_cache_usage_ -->|method_call| CACHE_PATTERNS_values
  CodebaseIndex__Extractors__CachingExtractor_annotate_source["CodebaseIndex::Extractors::CachingExtractor#annotate_source"]
  CodebaseIndex__Extractors__CachingExtractor_extract_metadata["CodebaseIndex::Extractors::CachingExtractor#extract_metadata"]
  CodebaseIndex__Extractors__CachingExtractor_extract_cache_calls["CodebaseIndex::Extractors::CachingExtractor#extract_cache_calls"]
  CACHE_PATTERNS["CACHE_PATTERNS"]
  CodebaseIndex__Extractors__CachingExtractor_extract_cache_calls -->|method_call| CACHE_PATTERNS
  CodebaseIndex__Extractors__CachingExtractor_extract_key_pattern["CodebaseIndex::Extractors::CachingExtractor#extract_key_pattern"]
  CodebaseIndex__Extractors__CachingExtractor_extract_ttl["CodebaseIndex::Extractors::CachingExtractor#extract_ttl"]
  CodebaseIndex__Extractors__CachingExtractor_infer_cache_strategy["CodebaseIndex::Extractors::CachingExtractor#infer_cache_strategy"]
  CodebaseIndex__Extractors__CachingExtractor_infer_file_type["CodebaseIndex::Extractors::CachingExtractor#infer_file_type"]
  CodebaseIndex__Extractors__CachingExtractor_relative_path["CodebaseIndex::Extractors::CachingExtractor#relative_path"]
  CodebaseIndex__Extractors__CachingExtractor_extract_dependencies["CodebaseIndex::Extractors::CachingExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__CallbackAnalyzer["CodebaseIndex::Extractors::CallbackAnalyzer"]
  CodebaseIndex__Extractors__CallbackAnalyzer_initialize["CodebaseIndex::Extractors::CallbackAnalyzer#initialize"]
  Ast__Parser["Ast::Parser"]
  CodebaseIndex__Extractors__CallbackAnalyzer_initialize -->|method_call| Ast__Parser
  FlowAnalysis__OperationExtractor["FlowAnalysis::OperationExtractor"]
  CodebaseIndex__Extractors__CallbackAnalyzer_initialize -->|method_call| FlowAnalysis__OperationExtractor
  CodebaseIndex__Extractors__CallbackAnalyzer_analyze["CodebaseIndex::Extractors::CallbackAnalyzer#analyze"]
  CodebaseIndex__Extractors__CallbackAnalyzer_safe_parse["CodebaseIndex::Extractors::CallbackAnalyzer#safe_parse"]
  CodebaseIndex__Extractors__CallbackAnalyzer_find_method_node["CodebaseIndex::Extractors::CallbackAnalyzer#find_method_node"]
  CodebaseIndex__Extractors__CallbackAnalyzer_method_source_from_node["CodebaseIndex::Extractors::CallbackAnalyzer#method_source_from_node"]
  CodebaseIndex__Extractors__CallbackAnalyzer_valid_method_name_["CodebaseIndex::Extractors::CallbackAnalyzer#valid_method_name?"]
  CodebaseIndex__Extractors__CallbackAnalyzer_detect_columns_written["CodebaseIndex::Extractors::CallbackAnalyzer#detect_columns_written"]
  CodebaseIndex__Extractors__CallbackAnalyzer_detect_columns_written -->|method_call| Set
  SINGLE_COLUMN_WRITERS["SINGLE_COLUMN_WRITERS"]
  CodebaseIndex__Extractors__CallbackAnalyzer_detect_columns_written -->|method_call| SINGLE_COLUMN_WRITERS
  MULTI_COLUMN_WRITERS["MULTI_COLUMN_WRITERS"]
  CodebaseIndex__Extractors__CallbackAnalyzer_detect_columns_written -->|method_call| MULTI_COLUMN_WRITERS
  CodebaseIndex__Extractors__CallbackAnalyzer_detect_jobs_enqueued["CodebaseIndex::Extractors::CallbackAnalyzer#detect_jobs_enqueued"]
  ASYNC_METHODS_map["ASYNC_METHODS.map"]
  CodebaseIndex__Extractors__CallbackAnalyzer_detect_jobs_enqueued -->|method_call| ASYNC_METHODS_map
  ASYNC_METHODS["ASYNC_METHODS"]
  CodebaseIndex__Extractors__CallbackAnalyzer_detect_jobs_enqueued -->|method_call| ASYNC_METHODS
  Regexp["Regexp"]
  CodebaseIndex__Extractors__CallbackAnalyzer_detect_jobs_enqueued -->|method_call| Regexp
  CodebaseIndex__Extractors__CallbackAnalyzer_detect_services_called["CodebaseIndex::Extractors::CallbackAnalyzer#detect_services_called"]
  CodebaseIndex__Extractors__CallbackAnalyzer_detect_mailers_triggered["CodebaseIndex::Extractors::CallbackAnalyzer#detect_mailers_triggered"]
  CodebaseIndex__Extractors__CallbackAnalyzer_detect_database_reads["CodebaseIndex::Extractors::CallbackAnalyzer#detect_database_reads"]
  DB_READ_METHODS["DB_READ_METHODS"]
  CodebaseIndex__Extractors__CallbackAnalyzer_detect_database_reads -->|method_call| DB_READ_METHODS
  CodebaseIndex__Extractors__CallbackAnalyzer_extract_operations["CodebaseIndex::Extractors::CallbackAnalyzer#extract_operations"]
  CodebaseIndex__Extractors__CallbackAnalyzer_empty_side_effects["CodebaseIndex::Extractors::CallbackAnalyzer#empty_side_effects"]
  CodebaseIndex__Extractors__ConcernExtractor["CodebaseIndex::Extractors::ConcernExtractor"]
  CodebaseIndex__Extractors__ConcernExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__ConcernExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__ConcernExtractor_initialize["CodebaseIndex::Extractors::ConcernExtractor#initialize"]
  CONCERN_DIRECTORIES_map["CONCERN_DIRECTORIES.map"]
  CodebaseIndex__Extractors__ConcernExtractor_initialize -->|method_call| CONCERN_DIRECTORIES_map
  CONCERN_DIRECTORIES["CONCERN_DIRECTORIES"]
  CodebaseIndex__Extractors__ConcernExtractor_initialize -->|method_call| CONCERN_DIRECTORIES
  CodebaseIndex__Extractors__ConcernExtractor_initialize -->|method_call| Rails_root
  CodebaseIndex__Extractors__ConcernExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__ConcernExtractor_extract_all["CodebaseIndex::Extractors::ConcernExtractor#extract_all"]
  CodebaseIndex__Extractors__ConcernExtractor_extract_all -->|method_call| Dir___
  CodebaseIndex__Extractors__ConcernExtractor_extract_concern_file["CodebaseIndex::Extractors::ConcernExtractor#extract_concern_file"]
  CodebaseIndex__Extractors__ConcernExtractor_extract_concern_file -->|method_call| File
  CodebaseIndex__Extractors__ConcernExtractor_extract_concern_file -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__ConcernExtractor_extract_concern_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__ConcernExtractor_extract_concern_file -->|method_call| Rails
  CodebaseIndex__Extractors__ConcernExtractor_extract_module_name["CodebaseIndex::Extractors::ConcernExtractor#extract_module_name"]
  CodebaseIndex__Extractors__ConcernExtractor_concern_module_["CodebaseIndex::Extractors::ConcernExtractor#concern_module?"]
  CodebaseIndex__Extractors__ConcernExtractor_annotate_source["CodebaseIndex::Extractors::ConcernExtractor#annotate_source"]
  CodebaseIndex__Extractors__ConcernExtractor_extract_metadata["CodebaseIndex::Extractors::ConcernExtractor#extract_metadata"]
  CodebaseIndex__Extractors__ConcernExtractor_detect_concern_type["CodebaseIndex::Extractors::ConcernExtractor#detect_concern_type"]
  CodebaseIndex__Extractors__ConcernExtractor_detect_concern_scope["CodebaseIndex::Extractors::ConcernExtractor#detect_concern_scope"]
  CodebaseIndex__Extractors__ConcernExtractor_extract_instance_method_names["CodebaseIndex::Extractors::ConcernExtractor#extract_instance_method_names"]
  CodebaseIndex__Extractors__ConcernExtractor_detect_included_modules["CodebaseIndex::Extractors::ConcernExtractor#detect_included_modules"]
  CodebaseIndex__Extractors__ConcernExtractor_detect_callbacks["CodebaseIndex::Extractors::ConcernExtractor#detect_callbacks"]
  CodebaseIndex__Extractors__ConcernExtractor_detect_scopes["CodebaseIndex::Extractors::ConcernExtractor#detect_scopes"]
  CodebaseIndex__Extractors__ConcernExtractor_detect_validations["CodebaseIndex::Extractors::ConcernExtractor#detect_validations"]
  CodebaseIndex__Extractors__ConcernExtractor_extract_dependencies["CodebaseIndex::Extractors::ConcernExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__ConfigurationExtractor["CodebaseIndex::Extractors::ConfigurationExtractor"]
  CodebaseIndex__Extractors__ConfigurationExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__ConfigurationExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__ConfigurationExtractor_initialize["CodebaseIndex::Extractors::ConfigurationExtractor#initialize"]
  CONFIG_DIRECTORIES_map["CONFIG_DIRECTORIES.map"]
  CodebaseIndex__Extractors__ConfigurationExtractor_initialize -->|method_call| CONFIG_DIRECTORIES_map
  CONFIG_DIRECTORIES["CONFIG_DIRECTORIES"]
  CodebaseIndex__Extractors__ConfigurationExtractor_initialize -->|method_call| CONFIG_DIRECTORIES
  CodebaseIndex__Extractors__ConfigurationExtractor_initialize -->|method_call| Rails_root
  CodebaseIndex__Extractors__ConfigurationExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__ConfigurationExtractor_extract_all["CodebaseIndex::Extractors::ConfigurationExtractor#extract_all"]
  CodebaseIndex__Extractors__ConfigurationExtractor_extract_all -->|method_call| Dir___
  BehavioralProfile_new["BehavioralProfile.new"]
  CodebaseIndex__Extractors__ConfigurationExtractor_extract_all -->|method_call| BehavioralProfile_new
  BehavioralProfile["BehavioralProfile"]
  CodebaseIndex__Extractors__ConfigurationExtractor_extract_all -->|method_call| BehavioralProfile
  CodebaseIndex__Extractors__ConfigurationExtractor_extract_all -->|method_call| Rails_logger
  CodebaseIndex__Extractors__ConfigurationExtractor_extract_all -->|method_call| Rails
  CodebaseIndex__Extractors__ConfigurationExtractor_extract_configuration_file["CodebaseIndex::Extractors::ConfigurationExtractor#extract_configuration_file"]
  CodebaseIndex__Extractors__ConfigurationExtractor_extract_configuration_file -->|method_call| File
  CodebaseIndex__Extractors__ConfigurationExtractor_extract_configuration_file -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__ConfigurationExtractor_extract_configuration_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__ConfigurationExtractor_extract_configuration_file -->|method_call| Rails
  CodebaseIndex__Extractors__ConfigurationExtractor_build_identifier["CodebaseIndex::Extractors::ConfigurationExtractor#build_identifier"]
  CodebaseIndex__Extractors__ConfigurationExtractor_detect_config_type["CodebaseIndex::Extractors::ConfigurationExtractor#detect_config_type"]
  CodebaseIndex__Extractors__ConfigurationExtractor_annotate_source["CodebaseIndex::Extractors::ConfigurationExtractor#annotate_source"]
  CodebaseIndex__Extractors__ConfigurationExtractor_extract_metadata["CodebaseIndex::Extractors::ConfigurationExtractor#extract_metadata"]
  CodebaseIndex__Extractors__ConfigurationExtractor_detect_gem_references["CodebaseIndex::Extractors::ConfigurationExtractor#detect_gem_references"]
  CodebaseIndex__Extractors__ConfigurationExtractor_detect_config_settings["CodebaseIndex::Extractors::ConfigurationExtractor#detect_config_settings"]
  CodebaseIndex__Extractors__ConfigurationExtractor_detect_rails_config_blocks["CodebaseIndex::Extractors::ConfigurationExtractor#detect_rails_config_blocks"]
  CodebaseIndex__Extractors__ConfigurationExtractor_generic_config_name_["CodebaseIndex::Extractors::ConfigurationExtractor#generic_config_name?"]
  CodebaseIndex__Extractors__ConfigurationExtractor_extract_dependencies["CodebaseIndex::Extractors::ConfigurationExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__ControllerExtractor["CodebaseIndex::Extractors::ControllerExtractor"]
  AstSourceExtraction["AstSourceExtraction"]
  CodebaseIndex__Extractors__ControllerExtractor -->|include| AstSourceExtraction
  CodebaseIndex__Extractors__ControllerExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__ControllerExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__ControllerExtractor_initialize["CodebaseIndex::Extractors::ControllerExtractor#initialize"]
  CodebaseIndex__Extractors__ControllerExtractor_extract_all["CodebaseIndex::Extractors::ControllerExtractor#extract_all"]
  ApplicationController["ApplicationController"]
  CodebaseIndex__Extractors__ControllerExtractor_extract_all -->|method_call| ApplicationController
  CodebaseIndex__Extractors__ControllerExtractor_extract_controller["CodebaseIndex::Extractors::ControllerExtractor#extract_controller"]
  CodebaseIndex__Extractors__ControllerExtractor_extract_controller -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__ControllerExtractor_extract_controller -->|method_call| File
  CodebaseIndex__Extractors__ControllerExtractor_extract_controller -->|method_call| Rails_logger
  CodebaseIndex__Extractors__ControllerExtractor_extract_controller -->|method_call| Rails
  CodebaseIndex__Extractors__ControllerExtractor_build_routes_map["CodebaseIndex::Extractors::ControllerExtractor#build_routes_map"]
  Rails_application_routes_routes["Rails.application.routes.routes"]
  CodebaseIndex__Extractors__ControllerExtractor_build_routes_map -->|method_call| Rails_application_routes_routes
  CodebaseIndex__Extractors__ControllerExtractor_extract_verb["CodebaseIndex::Extractors::ControllerExtractor#extract_verb"]
  CodebaseIndex__Extractors__ControllerExtractor_source_file_for["CodebaseIndex::Extractors::ControllerExtractor#source_file_for"]
  CodebaseIndex__Extractors__ControllerExtractor_source_file_for -->|method_call| Rails_root_join
  CodebaseIndex__Extractors__ControllerExtractor_source_file_for -->|method_call| Rails_root
  CodebaseIndex__Extractors__ControllerExtractor_source_file_for -->|method_call| Rails
  CodebaseIndex__Extractors__ControllerExtractor_build_composite_source["CodebaseIndex::Extractors::ControllerExtractor#build_composite_source"]
  CodebaseIndex__Extractors__ControllerExtractor_build_composite_source -->|method_call| File
  CodebaseIndex__Extractors__ControllerExtractor_build_routes_comment["CodebaseIndex::Extractors::ControllerExtractor#build_routes_comment"]
  CodebaseIndex__Extractors__ControllerExtractor_build_filters_comment["CodebaseIndex::Extractors::ControllerExtractor#build_filters_comment"]
  CodebaseIndex__Extractors__ControllerExtractor_extract_filter_chain["CodebaseIndex::Extractors::ControllerExtractor#extract_filter_chain"]
  CodebaseIndex__Extractors__ControllerExtractor_extract_callback_conditions["CodebaseIndex::Extractors::ControllerExtractor#extract_callback_conditions"]
  CodebaseIndex__Extractors__ControllerExtractor_extract_action_filter_actions["CodebaseIndex::Extractors::ControllerExtractor#extract_action_filter_actions"]
  CodebaseIndex__Extractors__ControllerExtractor_condition_label["CodebaseIndex::Extractors::ControllerExtractor#condition_label"]
  CodebaseIndex__Extractors__ControllerExtractor_extract_metadata["CodebaseIndex::Extractors::ControllerExtractor#extract_metadata"]
  CodebaseIndex__Extractors__ControllerExtractor_extract_included_concerns["CodebaseIndex::Extractors::ControllerExtractor#extract_included_concerns"]
  CodebaseIndex__Extractors__ControllerExtractor_extract_respond_formats["CodebaseIndex::Extractors::ControllerExtractor#extract_respond_formats"]
  CodebaseIndex__Extractors__ControllerExtractor_extract_respond_formats -->|method_call| File
  CodebaseIndex__Extractors__ControllerExtractor_extract_permitted_params["CodebaseIndex::Extractors::ControllerExtractor#extract_permitted_params"]
  CodebaseIndex__Extractors__ControllerExtractor_extract_permitted_params -->|method_call| File
  CodebaseIndex__Extractors__ControllerExtractor_extract_dependencies["CodebaseIndex::Extractors::ControllerExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__ControllerExtractor_extract_dependencies -->|method_call| File
  CodebaseIndex__Extractors__ControllerExtractor_build_action_chunks["CodebaseIndex::Extractors::ControllerExtractor#build_action_chunks"]
  CodebaseIndex__Extractors__ControllerExtractor_applicable_filters["CodebaseIndex::Extractors::ControllerExtractor#applicable_filters"]
  CodebaseIndex__Extractors__ControllerExtractor_callback_applies_to_action_["CodebaseIndex::Extractors::ControllerExtractor#callback_applies_to_action?"]
  CodebaseIndex__Extractors__DatabaseViewExtractor["CodebaseIndex::Extractors::DatabaseViewExtractor"]
  CodebaseIndex__Extractors__DatabaseViewExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__DatabaseViewExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__DatabaseViewExtractor_initialize["CodebaseIndex::Extractors::DatabaseViewExtractor#initialize"]
  CodebaseIndex__Extractors__DatabaseViewExtractor_initialize -->|method_call| Rails_root
  CodebaseIndex__Extractors__DatabaseViewExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__DatabaseViewExtractor_extract_all["CodebaseIndex::Extractors::DatabaseViewExtractor#extract_all"]
  CodebaseIndex__Extractors__DatabaseViewExtractor_extract_view_file["CodebaseIndex::Extractors::DatabaseViewExtractor#extract_view_file"]
  CodebaseIndex__Extractors__DatabaseViewExtractor_extract_view_file -->|method_call| File
  CodebaseIndex__Extractors__DatabaseViewExtractor_extract_view_file -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__DatabaseViewExtractor_extract_view_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__DatabaseViewExtractor_extract_view_file -->|method_call| Rails
  CodebaseIndex__Extractors__DatabaseViewExtractor_latest_view_files["CodebaseIndex::Extractors::DatabaseViewExtractor#latest_view_files"]
  CodebaseIndex__Extractors__DatabaseViewExtractor_latest_view_files -->|method_call| Dir___
  CodebaseIndex__Extractors__DatabaseViewExtractor_latest_view_files -->|method_call| File_basename
  CodebaseIndex__Extractors__DatabaseViewExtractor_latest_view_files -->|method_call| File
  CodebaseIndex__Extractors__DatabaseViewExtractor_extract_view_name["CodebaseIndex::Extractors::DatabaseViewExtractor#extract_view_name"]
  CodebaseIndex__Extractors__DatabaseViewExtractor_extract_view_name -->|method_call| File
  CodebaseIndex__Extractors__DatabaseViewExtractor_extract_version["CodebaseIndex::Extractors::DatabaseViewExtractor#extract_version"]
  CodebaseIndex__Extractors__DatabaseViewExtractor_extract_version -->|method_call| File
  CodebaseIndex__Extractors__DatabaseViewExtractor_annotate_source["CodebaseIndex::Extractors::DatabaseViewExtractor#annotate_source"]
  CodebaseIndex__Extractors__DatabaseViewExtractor_extract_metadata["CodebaseIndex::Extractors::DatabaseViewExtractor#extract_metadata"]
  CodebaseIndex__Extractors__DatabaseViewExtractor_materialized_view_["CodebaseIndex::Extractors::DatabaseViewExtractor#materialized_view?"]
  CodebaseIndex__Extractors__DatabaseViewExtractor_extract_referenced_tables["CodebaseIndex::Extractors::DatabaseViewExtractor#extract_referenced_tables"]
  CodebaseIndex__Extractors__DatabaseViewExtractor_extract_selected_columns["CodebaseIndex::Extractors::DatabaseViewExtractor#extract_selected_columns"]
  CodebaseIndex__Extractors__DatabaseViewExtractor_sql_keyword_["CodebaseIndex::Extractors::DatabaseViewExtractor#sql_keyword?"]
  SQL_KEYWORDS["SQL_KEYWORDS"]
  CodebaseIndex__Extractors__DatabaseViewExtractor_sql_keyword_ -->|method_call| SQL_KEYWORDS
  CodebaseIndex__Extractors__DatabaseViewExtractor_extract_dependencies["CodebaseIndex::Extractors::DatabaseViewExtractor#extract_dependencies"]
  INTERNAL_TABLES["INTERNAL_TABLES"]
  CodebaseIndex__Extractors__DatabaseViewExtractor_extract_dependencies -->|method_call| INTERNAL_TABLES
  CodebaseIndex__Extractors__DecoratorExtractor["CodebaseIndex::Extractors::DecoratorExtractor"]
  CodebaseIndex__Extractors__DecoratorExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__DecoratorExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__DecoratorExtractor_initialize["CodebaseIndex::Extractors::DecoratorExtractor#initialize"]
  DECORATOR_DIRECTORIES_map["DECORATOR_DIRECTORIES.map"]
  CodebaseIndex__Extractors__DecoratorExtractor_initialize -->|method_call| DECORATOR_DIRECTORIES_map
  DECORATOR_DIRECTORIES["DECORATOR_DIRECTORIES"]
  CodebaseIndex__Extractors__DecoratorExtractor_initialize -->|method_call| DECORATOR_DIRECTORIES
  CodebaseIndex__Extractors__DecoratorExtractor_initialize -->|method_call| Rails_root
  CodebaseIndex__Extractors__DecoratorExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__DecoratorExtractor_extract_all["CodebaseIndex::Extractors::DecoratorExtractor#extract_all"]
  CodebaseIndex__Extractors__DecoratorExtractor_extract_all -->|method_call| Dir___
  CodebaseIndex__Extractors__DecoratorExtractor_extract_decorator_file["CodebaseIndex::Extractors::DecoratorExtractor#extract_decorator_file"]
  CodebaseIndex__Extractors__DecoratorExtractor_extract_decorator_file -->|method_call| File
  CodebaseIndex__Extractors__DecoratorExtractor_extract_decorator_file -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__DecoratorExtractor_extract_decorator_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__DecoratorExtractor_extract_decorator_file -->|method_call| Rails
  CodebaseIndex__Extractors__DecoratorExtractor_extract_class_name["CodebaseIndex::Extractors::DecoratorExtractor#extract_class_name"]
  CodebaseIndex__Extractors__DecoratorExtractor_skip_file_["CodebaseIndex::Extractors::DecoratorExtractor#skip_file?"]
  CodebaseIndex__Extractors__DecoratorExtractor_annotate_source["CodebaseIndex::Extractors::DecoratorExtractor#annotate_source"]
  CodebaseIndex__Extractors__DecoratorExtractor_extract_metadata["CodebaseIndex::Extractors::DecoratorExtractor#extract_metadata"]
  CodebaseIndex__Extractors__DecoratorExtractor_infer_decorator_type["CodebaseIndex::Extractors::DecoratorExtractor#infer_decorator_type"]
  DIRECTORY_TYPE_MAP["DIRECTORY_TYPE_MAP"]
  CodebaseIndex__Extractors__DecoratorExtractor_infer_decorator_type -->|method_call| DIRECTORY_TYPE_MAP
  CodebaseIndex__Extractors__DecoratorExtractor_infer_decorated_model["CodebaseIndex::Extractors::DecoratorExtractor#infer_decorated_model"]
  DECORATOR_SUFFIXES["DECORATOR_SUFFIXES"]
  CodebaseIndex__Extractors__DecoratorExtractor_infer_decorated_model -->|method_call| DECORATOR_SUFFIXES
  CodebaseIndex__Extractors__DecoratorExtractor_draper_["CodebaseIndex::Extractors::DecoratorExtractor#draper?"]
  CodebaseIndex__Extractors__DecoratorExtractor_extract_delegated_methods["CodebaseIndex::Extractors::DecoratorExtractor#extract_delegated_methods"]
  CodebaseIndex__Extractors__DecoratorExtractor_detect_entry_points["CodebaseIndex::Extractors::DecoratorExtractor#detect_entry_points"]
  CodebaseIndex__Extractors__DecoratorExtractor_extract_dependencies["CodebaseIndex::Extractors::DecoratorExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__EngineExtractor["CodebaseIndex::Extractors::EngineExtractor"]
  CodebaseIndex__Extractors__EngineExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__EngineExtractor_initialize["CodebaseIndex::Extractors::EngineExtractor#initialize"]
  CodebaseIndex__Extractors__EngineExtractor_extract_all["CodebaseIndex::Extractors::EngineExtractor#extract_all"]
  CodebaseIndex__Extractors__EngineExtractor_engines_available_["CodebaseIndex::Extractors::EngineExtractor#engines_available?"]
  CodebaseIndex__Extractors__EngineExtractor_engines_available_ -->|method_call| Rails
  CodebaseIndex__Extractors__EngineExtractor_engines_available_ -->|method_call| Rails_application
  CodebaseIndex__Extractors__EngineExtractor_engine_subclasses["CodebaseIndex::Extractors::EngineExtractor#engine_subclasses"]
  Rails__Engine["Rails::Engine"]
  CodebaseIndex__Extractors__EngineExtractor_engine_subclasses -->|method_call| Rails__Engine
  ObjectSpace_each_object["ObjectSpace.each_object"]
  CodebaseIndex__Extractors__EngineExtractor_engine_subclasses -->|method_call| ObjectSpace_each_object
  CodebaseIndex__Extractors__EngineExtractor_build_mount_map["CodebaseIndex::Extractors::EngineExtractor#build_mount_map"]
  CodebaseIndex__Extractors__EngineExtractor_build_mount_map -->|method_call| Rails_application_routes_routes
  CodebaseIndex__Extractors__EngineExtractor_engine_class_["CodebaseIndex::Extractors::EngineExtractor#engine_class?"]
  CodebaseIndex__Extractors__EngineExtractor_extract_mount_path["CodebaseIndex::Extractors::EngineExtractor#extract_mount_path"]
  CodebaseIndex__Extractors__EngineExtractor_extract_engine["CodebaseIndex::Extractors::EngineExtractor#extract_engine"]
  CodebaseIndex__Extractors__EngineExtractor_extract_engine -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__EngineExtractor_extract_engine -->|method_call| Rails_logger
  CodebaseIndex__Extractors__EngineExtractor_extract_engine -->|method_call| Rails
  CodebaseIndex__Extractors__EngineExtractor_count_engine_routes["CodebaseIndex::Extractors::EngineExtractor#count_engine_routes"]
  CodebaseIndex__Extractors__EngineExtractor_extract_engine_controllers["CodebaseIndex::Extractors::EngineExtractor#extract_engine_controllers"]
  CodebaseIndex__Extractors__EngineExtractor_extract_engine_controllers -->|method_call| Set
  CodebaseIndex__Extractors__EngineExtractor_build_engine_source["CodebaseIndex::Extractors::EngineExtractor#build_engine_source"]
  CodebaseIndex__Extractors__EngineExtractor_build_engine_dependencies["CodebaseIndex::Extractors::EngineExtractor#build_engine_dependencies"]
  CodebaseIndex__Extractors__EventExtractor["CodebaseIndex::Extractors::EventExtractor"]
  CodebaseIndex__Extractors__EventExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__EventExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__EventExtractor_initialize["CodebaseIndex::Extractors::EventExtractor#initialize"]
  APP_DIRECTORIES_map["APP_DIRECTORIES.map"]
  CodebaseIndex__Extractors__EventExtractor_initialize -->|method_call| APP_DIRECTORIES_map
  APP_DIRECTORIES["APP_DIRECTORIES"]
  CodebaseIndex__Extractors__EventExtractor_initialize -->|method_call| APP_DIRECTORIES
  CodebaseIndex__Extractors__EventExtractor_initialize -->|method_call| Rails_root
  CodebaseIndex__Extractors__EventExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__EventExtractor_extract_all["CodebaseIndex::Extractors::EventExtractor#extract_all"]
  CodebaseIndex__Extractors__EventExtractor_scan_file["CodebaseIndex::Extractors::EventExtractor#scan_file"]
  CodebaseIndex__Extractors__EventExtractor_scan_file -->|method_call| File
  CodebaseIndex__Extractors__EventExtractor_scan_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__EventExtractor_scan_file -->|method_call| Rails
  CodebaseIndex__Extractors__EventExtractor_scan_active_support_notifications["CodebaseIndex::Extractors::EventExtractor#scan_active_support_notifications"]
  CodebaseIndex__Extractors__EventExtractor_scan_wisper_patterns["CodebaseIndex::Extractors::EventExtractor#scan_wisper_patterns"]
  CodebaseIndex__Extractors__EventExtractor_register_publisher["CodebaseIndex::Extractors::EventExtractor#register_publisher"]
  CodebaseIndex__Extractors__EventExtractor_register_subscriber["CodebaseIndex::Extractors::EventExtractor#register_subscriber"]
  CodebaseIndex__Extractors__EventExtractor_build_unit["CodebaseIndex::Extractors::EventExtractor#build_unit"]
  CodebaseIndex__Extractors__EventExtractor_build_unit -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__EventExtractor_load_source_files["CodebaseIndex::Extractors::EventExtractor#load_source_files"]
  CodebaseIndex__Extractors__EventExtractor_load_source_files -->|method_call| File
  CodebaseIndex__Extractors__EventExtractor_build_source_annotation["CodebaseIndex::Extractors::EventExtractor#build_source_annotation"]
  CodebaseIndex__Extractors__EventExtractor_build_dependencies["CodebaseIndex::Extractors::EventExtractor#build_dependencies"]
  CodebaseIndex__Extractors__FactoryExtractor["CodebaseIndex::Extractors::FactoryExtractor"]
  CodebaseIndex__Extractors__FactoryExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__FactoryExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__FactoryExtractor_initialize["CodebaseIndex::Extractors::FactoryExtractor#initialize"]
  FACTORY_DIRECTORIES_map["FACTORY_DIRECTORIES.map"]
  CodebaseIndex__Extractors__FactoryExtractor_initialize -->|method_call| FACTORY_DIRECTORIES_map
  FACTORY_DIRECTORIES["FACTORY_DIRECTORIES"]
  CodebaseIndex__Extractors__FactoryExtractor_initialize -->|method_call| FACTORY_DIRECTORIES
  CodebaseIndex__Extractors__FactoryExtractor_initialize -->|method_call| Rails_root
  CodebaseIndex__Extractors__FactoryExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__FactoryExtractor_extract_all["CodebaseIndex::Extractors::FactoryExtractor#extract_all"]
  CodebaseIndex__Extractors__FactoryExtractor_extract_all -->|method_call| Dir___
  CodebaseIndex__Extractors__FactoryExtractor_extract_factory_file["CodebaseIndex::Extractors::FactoryExtractor#extract_factory_file"]
  CodebaseIndex__Extractors__FactoryExtractor_extract_factory_file -->|method_call| File
  CodebaseIndex__Extractors__FactoryExtractor_extract_factory_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__FactoryExtractor_extract_factory_file -->|method_call| Rails
  CodebaseIndex__Extractors__FactoryExtractor_parse_factories["CodebaseIndex::Extractors::FactoryExtractor#parse_factories"]
  CodebaseIndex__Extractors__FactoryExtractor_match_factory["CodebaseIndex::Extractors::FactoryExtractor#match_factory"]
  CodebaseIndex__Extractors__FactoryExtractor_classify["CodebaseIndex::Extractors::FactoryExtractor#classify"]
  CodebaseIndex__Extractors__FactoryExtractor_block_opener_["CodebaseIndex::Extractors::FactoryExtractor#block_opener?"]
  CodebaseIndex__Extractors__FactoryExtractor_build_unit["CodebaseIndex::Extractors::FactoryExtractor#build_unit"]
  CodebaseIndex__Extractors__FactoryExtractor_build_unit -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__FactoryExtractor_build_source_annotation["CodebaseIndex::Extractors::FactoryExtractor#build_source_annotation"]
  CodebaseIndex__Extractors__FactoryExtractor_build_metadata["CodebaseIndex::Extractors::FactoryExtractor#build_metadata"]
  CodebaseIndex__Extractors__FactoryExtractor_extract_dependencies["CodebaseIndex::Extractors::FactoryExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__GraphQLExtractor["CodebaseIndex::Extractors::GraphQLExtractor"]
  CodebaseIndex__Extractors__GraphQLExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__GraphQLExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__GraphQLExtractor_initialize["CodebaseIndex::Extractors::GraphQLExtractor#initialize"]
  CodebaseIndex__Extractors__GraphQLExtractor_initialize -->|method_call| Rails_root
  CodebaseIndex__Extractors__GraphQLExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__GraphQLExtractor_extract_all["CodebaseIndex::Extractors::GraphQLExtractor#extract_all"]
  CodebaseIndex__Extractors__GraphQLExtractor_extract_all -->|method_call| Set
  CodebaseIndex__Extractors__GraphQLExtractor_extract_all -->|method_call| Dir___
  CodebaseIndex__Extractors__GraphQLExtractor_extract_graphql_file["CodebaseIndex::Extractors::GraphQLExtractor#extract_graphql_file"]
  CodebaseIndex__Extractors__GraphQLExtractor_extract_graphql_file -->|method_call| File
  CodebaseIndex__Extractors__GraphQLExtractor_extract_graphql_file -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__GraphQLExtractor_extract_graphql_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__GraphQLExtractor_extract_graphql_file -->|method_call| Rails
  CodebaseIndex__Extractors__GraphQLExtractor_graphql_available_["CodebaseIndex::Extractors::GraphQLExtractor#graphql_available?"]
  CodebaseIndex__Extractors__GraphQLExtractor_find_schema_class["CodebaseIndex::Extractors::GraphQLExtractor#find_schema_class"]
  GraphQL__Schema_descendants["GraphQL::Schema.descendants"]
  CodebaseIndex__Extractors__GraphQLExtractor_find_schema_class -->|method_call| GraphQL__Schema_descendants
  CodebaseIndex__Extractors__GraphQLExtractor_load_runtime_types["CodebaseIndex::Extractors::GraphQLExtractor#load_runtime_types"]
  CodebaseIndex__Extractors__GraphQLExtractor_extract_from_runtime_type["CodebaseIndex::Extractors::GraphQLExtractor#extract_from_runtime_type"]
  CodebaseIndex__Extractors__GraphQLExtractor_extract_from_runtime_type -->|method_call| File
  CodebaseIndex__Extractors__GraphQLExtractor_extract_from_runtime_type -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__GraphQLExtractor_extract_from_runtime_type -->|method_call| Rails_logger
  CodebaseIndex__Extractors__GraphQLExtractor_extract_from_runtime_type -->|method_call| Rails
  CodebaseIndex__Extractors__GraphQLExtractor_source_file_for_class["CodebaseIndex::Extractors::GraphQLExtractor#source_file_for_class"]
  CodebaseIndex__Extractors__GraphQLExtractor_source_file_for_class -->|method_call| Rails_root_join
  CodebaseIndex__Extractors__GraphQLExtractor_source_file_for_class -->|method_call| Rails_root
  CodebaseIndex__Extractors__GraphQLExtractor_source_file_for_class -->|method_call| Rails
  CodebaseIndex__Extractors__GraphQLExtractor_classify_runtime_type["CodebaseIndex::Extractors::GraphQLExtractor#classify_runtime_type"]
  CodebaseIndex__Extractors__GraphQLExtractor_classify_unit_type["CodebaseIndex::Extractors::GraphQLExtractor#classify_unit_type"]
  CodebaseIndex__Extractors__GraphQLExtractor_graphql_class_["CodebaseIndex::Extractors::GraphQLExtractor#graphql_class?"]
  CodebaseIndex__Extractors__GraphQLExtractor_extract_class_name["CodebaseIndex::Extractors::GraphQLExtractor#extract_class_name"]
  CodebaseIndex__Extractors__GraphQLExtractor_build_annotated_source["CodebaseIndex::Extractors::GraphQLExtractor#build_annotated_source"]
  CodebaseIndex__Extractors__GraphQLExtractor_format_type_label["CodebaseIndex::Extractors::GraphQLExtractor#format_type_label"]
  CodebaseIndex__Extractors__GraphQLExtractor_build_metadata["CodebaseIndex::Extractors::GraphQLExtractor#build_metadata"]
  CodebaseIndex__Extractors__GraphQLExtractor_detect_graphql_kind["CodebaseIndex::Extractors::GraphQLExtractor#detect_graphql_kind"]
  CodebaseIndex__Extractors__GraphQLExtractor_extract_parent_class["CodebaseIndex::Extractors::GraphQLExtractor#extract_parent_class"]
  CodebaseIndex__Extractors__GraphQLExtractor_extract_fields["CodebaseIndex::Extractors::GraphQLExtractor#extract_fields"]
  CodebaseIndex__Extractors__GraphQLExtractor_extract_fields_from_runtime["CodebaseIndex::Extractors::GraphQLExtractor#extract_fields_from_runtime"]
  CodebaseIndex__Extractors__GraphQLExtractor_field_nullable_["CodebaseIndex::Extractors::GraphQLExtractor#field_nullable?"]
  CodebaseIndex__Extractors__GraphQLExtractor_extract_fields_from_source["CodebaseIndex::Extractors::GraphQLExtractor#extract_fields_from_source"]
  CodebaseIndex__Extractors__GraphQLExtractor_extract_arguments["CodebaseIndex::Extractors::GraphQLExtractor#extract_arguments"]
  CodebaseIndex__Extractors__GraphQLExtractor_extract_arguments_from_runtime["CodebaseIndex::Extractors::GraphQLExtractor#extract_arguments_from_runtime"]
  CodebaseIndex__Extractors__GraphQLExtractor_extract_arguments_from_source["CodebaseIndex::Extractors::GraphQLExtractor#extract_arguments_from_source"]
  CodebaseIndex__Extractors__GraphQLExtractor_extract_interfaces["CodebaseIndex::Extractors::GraphQLExtractor#extract_interfaces"]
  CodebaseIndex__Extractors__GraphQLExtractor_extract_connections["CodebaseIndex::Extractors::GraphQLExtractor#extract_connections"]
  CodebaseIndex__Extractors__GraphQLExtractor_extract_resolver_references["CodebaseIndex::Extractors::GraphQLExtractor#extract_resolver_references"]
  CodebaseIndex__Extractors__GraphQLExtractor_extract_authorization["CodebaseIndex::Extractors::GraphQLExtractor#extract_authorization"]
  CodebaseIndex__Extractors__GraphQLExtractor_extract_complexity["CodebaseIndex::Extractors::GraphQLExtractor#extract_complexity"]
  CodebaseIndex__Extractors__GraphQLExtractor_extract_enum_values["CodebaseIndex::Extractors::GraphQLExtractor#extract_enum_values"]
  CodebaseIndex__Extractors__GraphQLExtractor_extract_union_members["CodebaseIndex::Extractors::GraphQLExtractor#extract_union_members"]
  CodebaseIndex__Extractors__GraphQLExtractor_count_fields["CodebaseIndex::Extractors::GraphQLExtractor#count_fields"]
  CodebaseIndex__Extractors__GraphQLExtractor_count_arguments["CodebaseIndex::Extractors::GraphQLExtractor#count_arguments"]
  CodebaseIndex__Extractors__GraphQLExtractor_extract_dependencies["CodebaseIndex::Extractors::GraphQLExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__GraphQLExtractor_build_chunks["CodebaseIndex::Extractors::GraphQLExtractor#build_chunks"]
  CodebaseIndex__Extractors__GraphQLExtractor_build_summary_chunk["CodebaseIndex::Extractors::GraphQLExtractor#build_summary_chunk"]
  CodebaseIndex__Extractors__GraphQLExtractor_build_field_group_chunk["CodebaseIndex::Extractors::GraphQLExtractor#build_field_group_chunk"]
  CodebaseIndex__Extractors__GraphQLExtractor_build_arguments_chunk["CodebaseIndex::Extractors::GraphQLExtractor#build_arguments_chunk"]
  CodebaseIndex__Extractors__I18nExtractor["CodebaseIndex::Extractors::I18nExtractor"]
  CodebaseIndex__Extractors__I18nExtractor_initialize["CodebaseIndex::Extractors::I18nExtractor#initialize"]
  I18N_DIRECTORIES_map["I18N_DIRECTORIES.map"]
  CodebaseIndex__Extractors__I18nExtractor_initialize -->|method_call| I18N_DIRECTORIES_map
  I18N_DIRECTORIES["I18N_DIRECTORIES"]
  CodebaseIndex__Extractors__I18nExtractor_initialize -->|method_call| I18N_DIRECTORIES
  CodebaseIndex__Extractors__I18nExtractor_initialize -->|method_call| Rails_root
  CodebaseIndex__Extractors__I18nExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__I18nExtractor_extract_all["CodebaseIndex::Extractors::I18nExtractor#extract_all"]
  CodebaseIndex__Extractors__I18nExtractor_extract_all -->|method_call| Dir___
  CodebaseIndex__Extractors__I18nExtractor_extract_i18n_file["CodebaseIndex::Extractors::I18nExtractor#extract_i18n_file"]
  CodebaseIndex__Extractors__I18nExtractor_extract_i18n_file -->|method_call| File
  YAML["YAML"]
  CodebaseIndex__Extractors__I18nExtractor_extract_i18n_file -->|method_call| YAML
  CodebaseIndex__Extractors__I18nExtractor_extract_i18n_file -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__I18nExtractor_extract_i18n_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__I18nExtractor_extract_i18n_file -->|method_call| Rails
  CodebaseIndex__Extractors__I18nExtractor_build_identifier["CodebaseIndex::Extractors::I18nExtractor#build_identifier"]
  CodebaseIndex__Extractors__I18nExtractor_build_metadata["CodebaseIndex::Extractors::I18nExtractor#build_metadata"]
  CodebaseIndex__Extractors__I18nExtractor_flatten_keys["CodebaseIndex::Extractors::I18nExtractor#flatten_keys"]
  CodebaseIndex__Extractors__JobExtractor["CodebaseIndex::Extractors::JobExtractor"]
  CodebaseIndex__Extractors__JobExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__JobExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__JobExtractor_initialize["CodebaseIndex::Extractors::JobExtractor#initialize"]
  JOB_DIRECTORIES_map["JOB_DIRECTORIES.map"]
  CodebaseIndex__Extractors__JobExtractor_initialize -->|method_call| JOB_DIRECTORIES_map
  JOB_DIRECTORIES["JOB_DIRECTORIES"]
  CodebaseIndex__Extractors__JobExtractor_initialize -->|method_call| JOB_DIRECTORIES
  CodebaseIndex__Extractors__JobExtractor_initialize -->|method_call| Rails_root
  CodebaseIndex__Extractors__JobExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__JobExtractor_extract_all["CodebaseIndex::Extractors::JobExtractor#extract_all"]
  CodebaseIndex__Extractors__JobExtractor_extract_all -->|method_call| Dir___
  ApplicationJob_descendants["ApplicationJob.descendants"]
  CodebaseIndex__Extractors__JobExtractor_extract_all -->|method_call| ApplicationJob_descendants
  CodebaseIndex__Extractors__JobExtractor_extract_job_file["CodebaseIndex::Extractors::JobExtractor#extract_job_file"]
  CodebaseIndex__Extractors__JobExtractor_extract_job_file -->|method_call| File
  CodebaseIndex__Extractors__JobExtractor_extract_job_file -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__JobExtractor_extract_job_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__JobExtractor_extract_job_file -->|method_call| Rails
  CodebaseIndex__Extractors__JobExtractor_extract_job_class["CodebaseIndex::Extractors::JobExtractor#extract_job_class"]
  CodebaseIndex__Extractors__JobExtractor_extract_job_class -->|method_call| File
  CodebaseIndex__Extractors__JobExtractor_extract_job_class -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__JobExtractor_extract_job_class -->|method_call| Rails_logger
  CodebaseIndex__Extractors__JobExtractor_extract_job_class -->|method_call| Rails
  CodebaseIndex__Extractors__JobExtractor_extract_class_name["CodebaseIndex::Extractors::JobExtractor#extract_class_name"]
  CodebaseIndex__Extractors__JobExtractor_extract_class_name -->|method_call| Regexp
  CodebaseIndex__Extractors__JobExtractor_job_file_["CodebaseIndex::Extractors::JobExtractor#job_file?"]
  CodebaseIndex__Extractors__JobExtractor_source_file_for["CodebaseIndex::Extractors::JobExtractor#source_file_for"]
  CodebaseIndex__Extractors__JobExtractor_source_file_for -->|method_call| Rails_root_join
  CodebaseIndex__Extractors__JobExtractor_source_file_for -->|method_call| Rails_root
  CodebaseIndex__Extractors__JobExtractor_source_file_for -->|method_call| Rails
  CodebaseIndex__Extractors__JobExtractor_annotate_source["CodebaseIndex::Extractors::JobExtractor#annotate_source"]
  CodebaseIndex__Extractors__JobExtractor_detect_job_type["CodebaseIndex::Extractors::JobExtractor#detect_job_type"]
  CodebaseIndex__Extractors__JobExtractor_extract_queue["CodebaseIndex::Extractors::JobExtractor#extract_queue"]
  CodebaseIndex__Extractors__JobExtractor_extract_queue -->|method_call| Regexp
  CodebaseIndex__Extractors__JobExtractor_extract_metadata_from_source["CodebaseIndex::Extractors::JobExtractor#extract_metadata_from_source"]
  CodebaseIndex__Extractors__JobExtractor_extract_metadata_from_class["CodebaseIndex::Extractors::JobExtractor#extract_metadata_from_class"]
  CodebaseIndex__Extractors__JobExtractor_extract_sidekiq_options["CodebaseIndex::Extractors::JobExtractor#extract_sidekiq_options"]
  CodebaseIndex__Extractors__JobExtractor_extract_sidekiq_options -->|method_call| Regexp
  CodebaseIndex__Extractors__JobExtractor_extract_retry_config["CodebaseIndex::Extractors::JobExtractor#extract_retry_config"]
  CodebaseIndex__Extractors__JobExtractor_extract_concurrency["CodebaseIndex::Extractors::JobExtractor#extract_concurrency"]
  CodebaseIndex__Extractors__JobExtractor_extract_perform_params["CodebaseIndex::Extractors::JobExtractor#extract_perform_params"]
  CodebaseIndex__Extractors__JobExtractor_extract_perform_params -->|method_call| Regexp
  CodebaseIndex__Extractors__JobExtractor_extract_discard_on["CodebaseIndex::Extractors::JobExtractor#extract_discard_on"]
  CodebaseIndex__Extractors__JobExtractor_extract_retry_on["CodebaseIndex::Extractors::JobExtractor#extract_retry_on"]
  CodebaseIndex__Extractors__JobExtractor_extract_callbacks["CodebaseIndex::Extractors::JobExtractor#extract_callbacks"]
  CodebaseIndex__Extractors__JobExtractor_extract_dependencies["CodebaseIndex::Extractors::JobExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__JobExtractor_extract_enqueued_jobs["CodebaseIndex::Extractors::JobExtractor#extract_enqueued_jobs"]
  CodebaseIndex__Extractors__MailerExtractor["CodebaseIndex::Extractors::MailerExtractor"]
  CodebaseIndex__Extractors__MailerExtractor -->|include| AstSourceExtraction
  CodebaseIndex__Extractors__MailerExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__MailerExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__MailerExtractor_initialize["CodebaseIndex::Extractors::MailerExtractor#initialize"]
  CodebaseIndex__Extractors__MailerExtractor_extract_all["CodebaseIndex::Extractors::MailerExtractor#extract_all"]
  CodebaseIndex__Extractors__MailerExtractor_extract_mailer["CodebaseIndex::Extractors::MailerExtractor#extract_mailer"]
  CodebaseIndex__Extractors__MailerExtractor_extract_mailer -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__MailerExtractor_extract_mailer -->|method_call| File
  CodebaseIndex__Extractors__MailerExtractor_extract_mailer -->|method_call| Rails_logger
  CodebaseIndex__Extractors__MailerExtractor_extract_mailer -->|method_call| Rails
  CodebaseIndex__Extractors__MailerExtractor_source_file_for["CodebaseIndex::Extractors::MailerExtractor#source_file_for"]
  CodebaseIndex__Extractors__MailerExtractor_source_file_for -->|method_call| Rails_root_join
  CodebaseIndex__Extractors__MailerExtractor_source_file_for -->|method_call| Rails_root
  CodebaseIndex__Extractors__MailerExtractor_source_file_for -->|method_call| Rails
  CodebaseIndex__Extractors__MailerExtractor_annotate_source["CodebaseIndex::Extractors::MailerExtractor#annotate_source"]
  CodebaseIndex__Extractors__MailerExtractor_extract_metadata["CodebaseIndex::Extractors::MailerExtractor#extract_metadata"]
  CodebaseIndex__Extractors__MailerExtractor_extract_defaults["CodebaseIndex::Extractors::MailerExtractor#extract_defaults"]
  CodebaseIndex__Extractors__MailerExtractor_extract_callbacks["CodebaseIndex::Extractors::MailerExtractor#extract_callbacks"]
  CodebaseIndex__Extractors__MailerExtractor_extract_callback_conditions["CodebaseIndex::Extractors::MailerExtractor#extract_callback_conditions"]
  CodebaseIndex__Extractors__MailerExtractor_extract_action_filter_actions["CodebaseIndex::Extractors::MailerExtractor#extract_action_filter_actions"]
  CodebaseIndex__Extractors__MailerExtractor_condition_label["CodebaseIndex::Extractors::MailerExtractor#condition_label"]
  CodebaseIndex__Extractors__MailerExtractor_extract_layout["CodebaseIndex::Extractors::MailerExtractor#extract_layout"]
  CodebaseIndex__Extractors__MailerExtractor_extract_layout -->|method_call| Regexp
  CodebaseIndex__Extractors__MailerExtractor_extract_helpers["CodebaseIndex::Extractors::MailerExtractor#extract_helpers"]
  CodebaseIndex__Extractors__MailerExtractor_discover_templates["CodebaseIndex::Extractors::MailerExtractor#discover_templates"]
  CodebaseIndex__Extractors__MailerExtractor_discover_templates -->|method_call| Rails_root
  CodebaseIndex__Extractors__MailerExtractor_discover_templates -->|method_call| Rails
  CodebaseIndex__Extractors__MailerExtractor_extract_dependencies["CodebaseIndex::Extractors::MailerExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__MailerExtractor_build_action_chunks["CodebaseIndex::Extractors::MailerExtractor#build_action_chunks"]
  CodebaseIndex__Extractors__ManagerExtractor["CodebaseIndex::Extractors::ManagerExtractor"]
  CodebaseIndex__Extractors__ManagerExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__ManagerExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__ManagerExtractor_initialize["CodebaseIndex::Extractors::ManagerExtractor#initialize"]
  MANAGER_DIRECTORIES_map["MANAGER_DIRECTORIES.map"]
  CodebaseIndex__Extractors__ManagerExtractor_initialize -->|method_call| MANAGER_DIRECTORIES_map
  MANAGER_DIRECTORIES["MANAGER_DIRECTORIES"]
  CodebaseIndex__Extractors__ManagerExtractor_initialize -->|method_call| MANAGER_DIRECTORIES
  CodebaseIndex__Extractors__ManagerExtractor_initialize -->|method_call| Rails_root
  CodebaseIndex__Extractors__ManagerExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__ManagerExtractor_extract_all["CodebaseIndex::Extractors::ManagerExtractor#extract_all"]
  CodebaseIndex__Extractors__ManagerExtractor_extract_all -->|method_call| Dir___
  CodebaseIndex__Extractors__ManagerExtractor_extract_manager_file["CodebaseIndex::Extractors::ManagerExtractor#extract_manager_file"]
  CodebaseIndex__Extractors__ManagerExtractor_extract_manager_file -->|method_call| File
  CodebaseIndex__Extractors__ManagerExtractor_extract_manager_file -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__ManagerExtractor_extract_manager_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__ManagerExtractor_extract_manager_file -->|method_call| Rails
  CodebaseIndex__Extractors__ManagerExtractor_extract_class_name["CodebaseIndex::Extractors::ManagerExtractor#extract_class_name"]
  CodebaseIndex__Extractors__ManagerExtractor_extract_class_name -->|method_call| Regexp
  CodebaseIndex__Extractors__ManagerExtractor_manager_file_["CodebaseIndex::Extractors::ManagerExtractor#manager_file?"]
  CodebaseIndex__Extractors__ManagerExtractor_annotate_source["CodebaseIndex::Extractors::ManagerExtractor#annotate_source"]
  CodebaseIndex__Extractors__ManagerExtractor_extract_metadata["CodebaseIndex::Extractors::ManagerExtractor#extract_metadata"]
  CodebaseIndex__Extractors__ManagerExtractor_detect_wrapped_model["CodebaseIndex::Extractors::ManagerExtractor#detect_wrapped_model"]
  CodebaseIndex__Extractors__ManagerExtractor_detect_wrapped_model -->|method_call| Regexp
  Regexp_last_match["Regexp.last_match"]
  CodebaseIndex__Extractors__ManagerExtractor_detect_wrapped_model -->|method_call| Regexp_last_match
  CodebaseIndex__Extractors__ManagerExtractor_detect_delegation_type["CodebaseIndex::Extractors::ManagerExtractor#detect_delegation_type"]
  CodebaseIndex__Extractors__ManagerExtractor_extract_delegated_methods["CodebaseIndex::Extractors::ManagerExtractor#extract_delegated_methods"]
  CodebaseIndex__Extractors__ManagerExtractor_extract_overridden_methods["CodebaseIndex::Extractors::ManagerExtractor#extract_overridden_methods"]
  CodebaseIndex__Extractors__ManagerExtractor_extract_custom_errors["CodebaseIndex::Extractors::ManagerExtractor#extract_custom_errors"]
  CodebaseIndex__Extractors__ManagerExtractor_extract_dependencies["CodebaseIndex::Extractors::ManagerExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__MiddlewareExtractor["CodebaseIndex::Extractors::MiddlewareExtractor"]
  CodebaseIndex__Extractors__MiddlewareExtractor_initialize["CodebaseIndex::Extractors::MiddlewareExtractor#initialize"]
  CodebaseIndex__Extractors__MiddlewareExtractor_extract_all["CodebaseIndex::Extractors::MiddlewareExtractor#extract_all"]
  CodebaseIndex__Extractors__MiddlewareExtractor_extract_all -->|method_call| Rails_application
  CodebaseIndex__Extractors__MiddlewareExtractor_extract_all -->|method_call| Rails
  CodebaseIndex__Extractors__MiddlewareExtractor_extract_all -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__MiddlewareExtractor_extract_all -->|method_call| Rails_logger
  CodebaseIndex__Extractors__MiddlewareExtractor_middleware_available_["CodebaseIndex::Extractors::MiddlewareExtractor#middleware_available?"]
  CodebaseIndex__Extractors__MiddlewareExtractor_middleware_available_ -->|method_call| Rails
  CodebaseIndex__Extractors__MiddlewareExtractor_middleware_available_ -->|method_call| Rails_application
  CodebaseIndex__Extractors__MiddlewareExtractor_extract_middleware_entries["CodebaseIndex::Extractors::MiddlewareExtractor#extract_middleware_entries"]
  CodebaseIndex__Extractors__MiddlewareExtractor_extract_single_middleware["CodebaseIndex::Extractors::MiddlewareExtractor#extract_single_middleware"]
  CodebaseIndex__Extractors__MiddlewareExtractor_build_stack_source["CodebaseIndex::Extractors::MiddlewareExtractor#build_stack_source"]
  CodebaseIndex__Extractors__MiddlewareExtractor_build_stack_metadata["CodebaseIndex::Extractors::MiddlewareExtractor#build_stack_metadata"]
  CodebaseIndex__Extractors__MigrationExtractor["CodebaseIndex::Extractors::MigrationExtractor"]
  CodebaseIndex__Extractors__MigrationExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__MigrationExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__MigrationExtractor_initialize["CodebaseIndex::Extractors::MigrationExtractor#initialize"]
  CodebaseIndex__Extractors__MigrationExtractor_initialize -->|method_call| Rails_root
  CodebaseIndex__Extractors__MigrationExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__MigrationExtractor_extract_all["CodebaseIndex::Extractors::MigrationExtractor#extract_all"]
  CodebaseIndex__Extractors__MigrationExtractor_extract_all -->|method_call| Dir
  CodebaseIndex__Extractors__MigrationExtractor_extract_migration_file["CodebaseIndex::Extractors::MigrationExtractor#extract_migration_file"]
  CodebaseIndex__Extractors__MigrationExtractor_extract_migration_file -->|method_call| File
  CodebaseIndex__Extractors__MigrationExtractor_extract_migration_file -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__MigrationExtractor_extract_migration_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__MigrationExtractor_extract_migration_file -->|method_call| Rails
  CodebaseIndex__Extractors__MigrationExtractor_extract_class_name["CodebaseIndex::Extractors::MigrationExtractor#extract_class_name"]
  CodebaseIndex__Extractors__MigrationExtractor_migration_class_["CodebaseIndex::Extractors::MigrationExtractor#migration_class?"]
  CodebaseIndex__Extractors__MigrationExtractor_extract_metadata["CodebaseIndex::Extractors::MigrationExtractor#extract_metadata"]
  CodebaseIndex__Extractors__MigrationExtractor_extract_migration_version["CodebaseIndex::Extractors::MigrationExtractor#extract_migration_version"]
  CodebaseIndex__Extractors__MigrationExtractor_extract_migration_version -->|method_call| File
  CodebaseIndex__Extractors__MigrationExtractor_extract_rails_version["CodebaseIndex::Extractors::MigrationExtractor#extract_rails_version"]
  CodebaseIndex__Extractors__MigrationExtractor_detect_direction["CodebaseIndex::Extractors::MigrationExtractor#detect_direction"]
  CodebaseIndex__Extractors__MigrationExtractor_extract_tables_affected["CodebaseIndex::Extractors::MigrationExtractor#extract_tables_affected"]
  TABLE_OPERATIONS["TABLE_OPERATIONS"]
  CodebaseIndex__Extractors__MigrationExtractor_extract_tables_affected -->|method_call| TABLE_OPERATIONS
  CodebaseIndex__Extractors__MigrationExtractor_extract_columns_added["CodebaseIndex::Extractors::MigrationExtractor#extract_columns_added"]
  CodebaseIndex__Extractors__MigrationExtractor_extract_columns_removed["CodebaseIndex::Extractors::MigrationExtractor#extract_columns_removed"]
  CodebaseIndex__Extractors__MigrationExtractor_extract_indexes_added["CodebaseIndex::Extractors::MigrationExtractor#extract_indexes_added"]
  CodebaseIndex__Extractors__MigrationExtractor_extract_indexes_removed["CodebaseIndex::Extractors::MigrationExtractor#extract_indexes_removed"]
  CodebaseIndex__Extractors__MigrationExtractor_extract_references_added["CodebaseIndex::Extractors::MigrationExtractor#extract_references_added"]
  CodebaseIndex__Extractors__MigrationExtractor_extract_references_removed["CodebaseIndex::Extractors::MigrationExtractor#extract_references_removed"]
  CodebaseIndex__Extractors__MigrationExtractor_extract_block_columns["CodebaseIndex::Extractors::MigrationExtractor#extract_block_columns"]
  COLUMN_TYPE_METHODS["COLUMN_TYPE_METHODS"]
  CodebaseIndex__Extractors__MigrationExtractor_extract_block_columns -->|method_call| COLUMN_TYPE_METHODS
  CodebaseIndex__Extractors__MigrationExtractor_extract_explicit_column_calls["CodebaseIndex::Extractors::MigrationExtractor#extract_explicit_column_calls"]
  CodebaseIndex__Extractors__MigrationExtractor_extract_block_references["CodebaseIndex::Extractors::MigrationExtractor#extract_block_references"]
  CodebaseIndex__Extractors__MigrationExtractor_extract_operations["CodebaseIndex::Extractors::MigrationExtractor#extract_operations"]
  CodebaseIndex__Extractors__MigrationExtractor_extract_operations -->|method_call| Hash
  CodebaseIndex__Extractors__MigrationExtractor_extract_operations -->|method_call| TABLE_OPERATIONS
  CodebaseIndex__Extractors__MigrationExtractor_data_migration_["CodebaseIndex::Extractors::MigrationExtractor#data_migration?"]
  DATA_MIGRATION_PATTERNS["DATA_MIGRATION_PATTERNS"]
  CodebaseIndex__Extractors__MigrationExtractor_data_migration_ -->|method_call| DATA_MIGRATION_PATTERNS
  CodebaseIndex__Extractors__MigrationExtractor_annotate_source["CodebaseIndex::Extractors::MigrationExtractor#annotate_source"]
  CodebaseIndex__Extractors__MigrationExtractor_extract_dependencies["CodebaseIndex::Extractors::MigrationExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__MigrationExtractor_extract_dependencies -->|method_call| INTERNAL_TABLES
  CodebaseIndex__Extractors__ModelExtractor["CodebaseIndex::Extractors::ModelExtractor"]
  CodebaseIndex__Extractors__ModelExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__ModelExtractor_initialize["CodebaseIndex::Extractors::ModelExtractor#initialize"]
  CodebaseIndex__Extractors__ModelExtractor_extract_all["CodebaseIndex::Extractors::ModelExtractor#extract_all"]
  ActiveRecord__Base_descendants_reject_reject_reject_map["ActiveRecord::Base.descendants.reject.reject.reject.map"]
  CodebaseIndex__Extractors__ModelExtractor_extract_all -->|method_call| ActiveRecord__Base_descendants_reject_reject_reject_map
  ActiveRecord__Base_descendants_reject_reject_reject["ActiveRecord::Base.descendants.reject.reject.reject"]
  CodebaseIndex__Extractors__ModelExtractor_extract_all -->|method_call| ActiveRecord__Base_descendants_reject_reject_reject
  CodebaseIndex__Extractors__ModelExtractor_extract_model["CodebaseIndex::Extractors::ModelExtractor#extract_model"]
  CodebaseIndex__Extractors__ModelExtractor_extract_model -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__ModelExtractor_extract_model -->|method_call| File
  CodebaseIndex__Extractors__ModelExtractor_extract_model -->|method_call| Rails_logger
  CodebaseIndex__Extractors__ModelExtractor_extract_model -->|method_call| Rails
  CodebaseIndex__Extractors__ModelExtractor_source_file_for["CodebaseIndex::Extractors::ModelExtractor#source_file_for"]
  CodebaseIndex__Extractors__ModelExtractor_source_file_for -->|method_call| Rails_root
  CodebaseIndex__Extractors__ModelExtractor_source_file_for -->|method_call| Rails
  CodebaseIndex__Extractors__ModelExtractor_source_file_for -->|method_call| Rails_root_join
  CodebaseIndex__Extractors__ModelExtractor_source_file_for -->|method_call| File
  CodebaseIndex__Extractors__ModelExtractor_source_file_for -->|method_call| Object
  Object_const_source_location["Object.const_source_location"]
  CodebaseIndex__Extractors__ModelExtractor_source_file_for -->|method_call| Object_const_source_location
  CodebaseIndex__Extractors__ModelExtractor_habtm_join_model_["CodebaseIndex::Extractors::ModelExtractor#habtm_join_model?"]
  CodebaseIndex__Extractors__ModelExtractor_build_composite_source["CodebaseIndex::Extractors::ModelExtractor#build_composite_source"]
  CodebaseIndex__Extractors__ModelExtractor_build_schema_comment["CodebaseIndex::Extractors::ModelExtractor#build_schema_comment"]
  CodebaseIndex__Extractors__ModelExtractor_format_columns_comment["CodebaseIndex::Extractors::ModelExtractor#format_columns_comment"]
  CodebaseIndex__Extractors__ModelExtractor_format_indexes_comment["CodebaseIndex::Extractors::ModelExtractor#format_indexes_comment"]
  ActiveRecord__Base_connection_indexes["ActiveRecord::Base.connection.indexes"]
  CodebaseIndex__Extractors__ModelExtractor_format_indexes_comment -->|method_call| ActiveRecord__Base_connection_indexes
  CodebaseIndex__Extractors__ModelExtractor_format_foreign_keys_comment["CodebaseIndex::Extractors::ModelExtractor#format_foreign_keys_comment"]
  ActiveRecord__Base_connection_foreign_keys["ActiveRecord::Base.connection.foreign_keys"]
  CodebaseIndex__Extractors__ModelExtractor_format_foreign_keys_comment -->|method_call| ActiveRecord__Base_connection_foreign_keys
  CodebaseIndex__Extractors__ModelExtractor_build_model_source_with_concerns["CodebaseIndex::Extractors::ModelExtractor#build_model_source_with_concerns"]
  CodebaseIndex__Extractors__ModelExtractor_build_model_source_with_concerns -->|method_call| File
  CodebaseIndex__Extractors__ModelExtractor_extract_included_modules["CodebaseIndex::Extractors::ModelExtractor#extract_included_modules"]
  CodebaseIndex__Extractors__ModelExtractor_extract_included_modules -->|method_call| Rails_root
  CodebaseIndex__Extractors__ModelExtractor_extract_included_modules -->|method_call| Rails
  CodebaseIndex__Extractors__ModelExtractor_extract_included_modules -->|method_call| Object
  CodebaseIndex__Extractors__ModelExtractor_defined_in_app_["CodebaseIndex::Extractors::ModelExtractor#defined_in_app?"]
  CodebaseIndex__Extractors__ModelExtractor_defined_in_app_ -->|method_call| Object
  CodebaseIndex__Extractors__ModelExtractor_concern_source["CodebaseIndex::Extractors::ModelExtractor#concern_source"]
  CodebaseIndex__Extractors__ModelExtractor_concern_source -->|method_call| File
  CodebaseIndex__Extractors__ModelExtractor_concern_path_for["CodebaseIndex::Extractors::ModelExtractor#concern_path_for"]
  CodebaseIndex__Extractors__ModelExtractor_concern_path_for -->|method_call| Rails_root
  CodebaseIndex__Extractors__ModelExtractor_concern_path_for -->|method_call| Rails
  CodebaseIndex__Extractors__ModelExtractor_concern_path_for -->|method_call| File
  CodebaseIndex__Extractors__ModelExtractor_extract_metadata["CodebaseIndex::Extractors::ModelExtractor#extract_metadata"]
  CodebaseIndex__Extractors__ModelExtractor_extract_active_storage_attachments["CodebaseIndex::Extractors::ModelExtractor#extract_active_storage_attachments"]
  CodebaseIndex__Extractors__ModelExtractor_extract_action_text_fields["CodebaseIndex::Extractors::ModelExtractor#extract_action_text_fields"]
  CodebaseIndex__Extractors__ModelExtractor_extract_variant_definitions["CodebaseIndex::Extractors::ModelExtractor#extract_variant_definitions"]
  CodebaseIndex__Extractors__ModelExtractor_extract_database_roles["CodebaseIndex::Extractors::ModelExtractor#extract_database_roles"]
  CodebaseIndex__Extractors__ModelExtractor_extract_shard_config["CodebaseIndex::Extractors::ModelExtractor#extract_shard_config"]
  CodebaseIndex__Extractors__ModelExtractor_parse_role_hash["CodebaseIndex::Extractors::ModelExtractor#parse_role_hash"]
  CodebaseIndex__Extractors__ModelExtractor_extract_associations["CodebaseIndex::Extractors::ModelExtractor#extract_associations"]
  CodebaseIndex__Extractors__ModelExtractor_extract_association_options["CodebaseIndex::Extractors::ModelExtractor#extract_association_options"]
  CodebaseIndex__Extractors__ModelExtractor_extract_validations["CodebaseIndex::Extractors::ModelExtractor#extract_validations"]
  CodebaseIndex__Extractors__ModelExtractor_extract_callbacks["CodebaseIndex::Extractors::ModelExtractor#extract_callbacks"]
  CodebaseIndex__Extractors__ModelExtractor_extract_scopes["CodebaseIndex::Extractors::ModelExtractor#extract_scopes"]
  CodebaseIndex__Extractors__ModelExtractor_extract_scopes -->|method_call| File
  CodebaseIndex__Extractors__ModelExtractor_extract_scopes -->|method_call| Ast__Parser
  CodebaseIndex__Extractors__ModelExtractor_extract_scopes_from_ast["CodebaseIndex::Extractors::ModelExtractor#extract_scopes_from_ast"]
  CodebaseIndex__Extractors__ModelExtractor_extract_scopes_by_regex["CodebaseIndex::Extractors::ModelExtractor#extract_scopes_by_regex"]
  CodebaseIndex__Extractors__ModelExtractor_extract_enums["CodebaseIndex::Extractors::ModelExtractor#extract_enums"]
  CodebaseIndex__Extractors__ModelExtractor_extract_dependencies["CodebaseIndex::Extractors::ModelExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__ModelExtractor_extract_dependencies -->|method_call| File
  CodebaseIndex__Extractors__ModelExtractor_enrich_callbacks_with_side_effects["CodebaseIndex::Extractors::ModelExtractor#enrich_callbacks_with_side_effects"]
  CallbackAnalyzer["CallbackAnalyzer"]
  CodebaseIndex__Extractors__ModelExtractor_enrich_callbacks_with_side_effects -->|method_call| CallbackAnalyzer
  CodebaseIndex__Extractors__ModelExtractor_build_chunks["CodebaseIndex::Extractors::ModelExtractor#build_chunks"]
  CodebaseIndex__Extractors__ModelExtractor_add_chunk["CodebaseIndex::Extractors::ModelExtractor#add_chunk"]
  CodebaseIndex__Extractors__ModelExtractor_build_summary_chunk["CodebaseIndex::Extractors::ModelExtractor#build_summary_chunk"]
  CodebaseIndex__Extractors__ModelExtractor_build_associations_chunk["CodebaseIndex::Extractors::ModelExtractor#build_associations_chunk"]
  CodebaseIndex__Extractors__ModelExtractor_build_callbacks_chunk["CodebaseIndex::Extractors::ModelExtractor#build_callbacks_chunk"]
  CodebaseIndex__Extractors__ModelExtractor_format_callback_line["CodebaseIndex::Extractors::ModelExtractor#format_callback_line"]
  CodebaseIndex__Extractors__ModelExtractor_build_callback_effects_chunk["CodebaseIndex::Extractors::ModelExtractor#build_callback_effects_chunk"]
  CodebaseIndex__Extractors__ModelExtractor_callback_lifecycle_group["CodebaseIndex::Extractors::ModelExtractor#callback_lifecycle_group"]
  CodebaseIndex__Extractors__ModelExtractor_describe_callback_effects["CodebaseIndex::Extractors::ModelExtractor#describe_callback_effects"]
  CodebaseIndex__Extractors__ModelExtractor_build_validations_chunk["CodebaseIndex::Extractors::ModelExtractor#build_validations_chunk"]
  CodebaseIndex__Extractors__ModelExtractor_condition_label["CodebaseIndex::Extractors::ModelExtractor#condition_label"]
  CodebaseIndex__Extractors__ModelExtractor_format_validation_conditions["CodebaseIndex::Extractors::ModelExtractor#format_validation_conditions"]
  CodebaseIndex__Extractors__ModelExtractor_format_callback_conditions["CodebaseIndex::Extractors::ModelExtractor#format_callback_conditions"]
  CodebaseIndex__Extractors__ModelExtractor_implicit_belongs_to_validator_["CodebaseIndex::Extractors::ModelExtractor#implicit_belongs_to_validator?"]
  CodebaseIndex__Extractors__ModelExtractor_filter_instance_methods["CodebaseIndex::Extractors::ModelExtractor#filter_instance_methods"]
  AR_INTERNAL_METHOD_PATTERNS["AR_INTERNAL_METHOD_PATTERNS"]
  CodebaseIndex__Extractors__ModelExtractor_filter_instance_methods -->|method_call| AR_INTERNAL_METHOD_PATTERNS
  CodebaseIndex__Extractors__ModelExtractor_sti_base_["CodebaseIndex::Extractors::ModelExtractor#sti_base?"]
  CodebaseIndex__Extractors__ModelExtractor_sti_child_["CodebaseIndex::Extractors::ModelExtractor#sti_child?"]
  CodebaseIndex__Extractors__ModelExtractor_callback_count["CodebaseIndex::Extractors::ModelExtractor#callback_count"]
  CodebaseIndex__Extractors__ModelExtractor_count_loc["CodebaseIndex::Extractors::ModelExtractor#count_loc"]
  CodebaseIndex__Extractors__ModelExtractor_count_loc -->|method_call| File
  CodebaseIndex__Extractors__ModelExtractor_count_loc -->|method_call| File_readlines
  CodebaseIndex__Extractors__PhlexExtractor["CodebaseIndex::Extractors::PhlexExtractor"]
  CodebaseIndex__Extractors__PhlexExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__PhlexExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__PhlexExtractor_initialize["CodebaseIndex::Extractors::PhlexExtractor#initialize"]
  CodebaseIndex__Extractors__PhlexExtractor_extract_all["CodebaseIndex::Extractors::PhlexExtractor#extract_all"]
  CodebaseIndex__Extractors__PhlexExtractor_extract_component["CodebaseIndex::Extractors::PhlexExtractor#extract_component"]
  CodebaseIndex__Extractors__PhlexExtractor_extract_component -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__PhlexExtractor_extract_component -->|method_call| Rails_logger
  CodebaseIndex__Extractors__PhlexExtractor_extract_component -->|method_call| Rails
  CodebaseIndex__Extractors__PhlexExtractor_find_component_base["CodebaseIndex::Extractors::PhlexExtractor#find_component_base"]
  PHLEX_BASES["PHLEX_BASES"]
  CodebaseIndex__Extractors__PhlexExtractor_find_component_base -->|method_call| PHLEX_BASES
  CodebaseIndex__Extractors__PhlexExtractor_view_component_subclass_["CodebaseIndex::Extractors::PhlexExtractor#view_component_subclass?"]
  CodebaseIndex__Extractors__PhlexExtractor_source_file_for["CodebaseIndex::Extractors::PhlexExtractor#source_file_for"]
  CodebaseIndex__Extractors__PhlexExtractor_source_file_for -->|method_call| Rails_root
  CodebaseIndex__Extractors__PhlexExtractor_source_file_for -->|method_call| Rails
  CodebaseIndex__Extractors__PhlexExtractor_source_file_for -->|method_call| File
  CodebaseIndex__Extractors__PhlexExtractor_read_source["CodebaseIndex::Extractors::PhlexExtractor#read_source"]
  CodebaseIndex__Extractors__PhlexExtractor_read_source -->|method_call| File
  CodebaseIndex__Extractors__PhlexExtractor_extract_metadata["CodebaseIndex::Extractors::PhlexExtractor#extract_metadata"]
  CodebaseIndex__Extractors__PhlexExtractor_extract_slots["CodebaseIndex::Extractors::PhlexExtractor#extract_slots"]
  CodebaseIndex__Extractors__PhlexExtractor_extract_renders_many["CodebaseIndex::Extractors::PhlexExtractor#extract_renders_many"]
  CodebaseIndex__Extractors__PhlexExtractor_extract_renders_one["CodebaseIndex::Extractors::PhlexExtractor#extract_renders_one"]
  CodebaseIndex__Extractors__PhlexExtractor_extract_initialize_params["CodebaseIndex::Extractors::PhlexExtractor#extract_initialize_params"]
  CodebaseIndex__Extractors__PhlexExtractor_extract_dependencies["CodebaseIndex::Extractors::PhlexExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__PolicyExtractor["CodebaseIndex::Extractors::PolicyExtractor"]
  CodebaseIndex__Extractors__PolicyExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__PolicyExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__PolicyExtractor_initialize["CodebaseIndex::Extractors::PolicyExtractor#initialize"]
  POLICY_DIRECTORIES_map["POLICY_DIRECTORIES.map"]
  CodebaseIndex__Extractors__PolicyExtractor_initialize -->|method_call| POLICY_DIRECTORIES_map
  POLICY_DIRECTORIES["POLICY_DIRECTORIES"]
  CodebaseIndex__Extractors__PolicyExtractor_initialize -->|method_call| POLICY_DIRECTORIES
  CodebaseIndex__Extractors__PolicyExtractor_initialize -->|method_call| Rails_root
  CodebaseIndex__Extractors__PolicyExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__PolicyExtractor_extract_all["CodebaseIndex::Extractors::PolicyExtractor#extract_all"]
  CodebaseIndex__Extractors__PolicyExtractor_extract_all -->|method_call| Dir___
  CodebaseIndex__Extractors__PolicyExtractor_extract_policy_file["CodebaseIndex::Extractors::PolicyExtractor#extract_policy_file"]
  CodebaseIndex__Extractors__PolicyExtractor_extract_policy_file -->|method_call| File
  CodebaseIndex__Extractors__PolicyExtractor_extract_policy_file -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__PolicyExtractor_extract_policy_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__PolicyExtractor_extract_policy_file -->|method_call| Rails
  CodebaseIndex__Extractors__PolicyExtractor_extract_class_name["CodebaseIndex::Extractors::PolicyExtractor#extract_class_name"]
  CodebaseIndex__Extractors__PolicyExtractor_extract_class_name -->|method_call| Regexp
  CodebaseIndex__Extractors__PolicyExtractor_skip_file_["CodebaseIndex::Extractors::PolicyExtractor#skip_file?"]
  CodebaseIndex__Extractors__PolicyExtractor_annotate_source["CodebaseIndex::Extractors::PolicyExtractor#annotate_source"]
  CodebaseIndex__Extractors__PolicyExtractor_extract_metadata["CodebaseIndex::Extractors::PolicyExtractor#extract_metadata"]
  CodebaseIndex__Extractors__PolicyExtractor_detect_decision_methods["CodebaseIndex::Extractors::PolicyExtractor#detect_decision_methods"]
  CodebaseIndex__Extractors__PolicyExtractor_detect_decision_methods -->|method_call| Regexp
  CodebaseIndex__Extractors__PolicyExtractor_detect_evaluated_models["CodebaseIndex::Extractors::PolicyExtractor#detect_evaluated_models"]
  CodebaseIndex__Extractors__PolicyExtractor_detect_evaluated_models -->|method_call| Regexp
  CodebaseIndex__Extractors__PolicyExtractor_detect_evaluated_models -->|method_call| Regexp_last_match
  CodebaseIndex__Extractors__PolicyExtractor_pundit_policy_["CodebaseIndex::Extractors::PolicyExtractor#pundit_policy?"]
  CodebaseIndex__Extractors__PolicyExtractor_extract_custom_errors["CodebaseIndex::Extractors::PolicyExtractor#extract_custom_errors"]
  CodebaseIndex__Extractors__PolicyExtractor_extract_dependencies["CodebaseIndex::Extractors::PolicyExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__PunditExtractor["CodebaseIndex::Extractors::PunditExtractor"]
  CodebaseIndex__Extractors__PunditExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__PunditExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__PunditExtractor_initialize["CodebaseIndex::Extractors::PunditExtractor#initialize"]
  PUNDIT_DIRECTORIES_map["PUNDIT_DIRECTORIES.map"]
  CodebaseIndex__Extractors__PunditExtractor_initialize -->|method_call| PUNDIT_DIRECTORIES_map
  PUNDIT_DIRECTORIES["PUNDIT_DIRECTORIES"]
  CodebaseIndex__Extractors__PunditExtractor_initialize -->|method_call| PUNDIT_DIRECTORIES
  CodebaseIndex__Extractors__PunditExtractor_initialize -->|method_call| Rails_root
  CodebaseIndex__Extractors__PunditExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__PunditExtractor_extract_all["CodebaseIndex::Extractors::PunditExtractor#extract_all"]
  CodebaseIndex__Extractors__PunditExtractor_extract_all -->|method_call| Dir___
  CodebaseIndex__Extractors__PunditExtractor_extract_pundit_file["CodebaseIndex::Extractors::PunditExtractor#extract_pundit_file"]
  CodebaseIndex__Extractors__PunditExtractor_extract_pundit_file -->|method_call| File
  CodebaseIndex__Extractors__PunditExtractor_extract_pundit_file -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__PunditExtractor_extract_pundit_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__PunditExtractor_extract_pundit_file -->|method_call| Rails
  CodebaseIndex__Extractors__PunditExtractor_extract_class_name["CodebaseIndex::Extractors::PunditExtractor#extract_class_name"]
  CodebaseIndex__Extractors__PunditExtractor_extract_class_name -->|method_call| Regexp
  CodebaseIndex__Extractors__PunditExtractor_pundit_policy_["CodebaseIndex::Extractors::PunditExtractor#pundit_policy?"]
  CodebaseIndex__Extractors__PunditExtractor_annotate_source["CodebaseIndex::Extractors::PunditExtractor#annotate_source"]
  CodebaseIndex__Extractors__PunditExtractor_extract_metadata["CodebaseIndex::Extractors::PunditExtractor#extract_metadata"]
  CodebaseIndex__Extractors__PunditExtractor_detect_authorization_actions["CodebaseIndex::Extractors::PunditExtractor#detect_authorization_actions"]
  CodebaseIndex__Extractors__PunditExtractor_infer_model["CodebaseIndex::Extractors::PunditExtractor#infer_model"]
  CodebaseIndex__Extractors__PunditExtractor_extract_dependencies["CodebaseIndex::Extractors::PunditExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__RailsSourceExtractor["CodebaseIndex::Extractors::RailsSourceExtractor"]
  CodebaseIndex__Extractors__RailsSourceExtractor_initialize["CodebaseIndex::Extractors::RailsSourceExtractor#initialize"]
  CodebaseIndex__Extractors__RailsSourceExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_all["CodebaseIndex::Extractors::RailsSourceExtractor#extract_all"]
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_rails_sources["CodebaseIndex::Extractors::RailsSourceExtractor#extract_rails_sources"]
  RAILS_PATHS["RAILS_PATHS"]
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_rails_sources -->|method_call| RAILS_PATHS
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_rails_sources -->|method_call| Dir___
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_gem_sources["CodebaseIndex::Extractors::RailsSourceExtractor#extract_gem_sources"]
  GEM_CONFIGS["GEM_CONFIGS"]
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_gem_sources -->|method_call| GEM_CONFIGS
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_gem_sources -->|method_call| Dir___
  CodebaseIndex__Extractors__RailsSourceExtractor_find_gem_path["CodebaseIndex::Extractors::RailsSourceExtractor#find_gem_path"]
  Gem__Specification["Gem::Specification"]
  CodebaseIndex__Extractors__RailsSourceExtractor_find_gem_path -->|method_call| Gem__Specification
  CodebaseIndex__Extractors__RailsSourceExtractor_find_gem_path -->|method_call| Pathname
  CodebaseIndex__Extractors__RailsSourceExtractor_gem_version["CodebaseIndex::Extractors::RailsSourceExtractor#gem_version"]
  Gem__Specification_find_by_name_version["Gem::Specification.find_by_name.version"]
  CodebaseIndex__Extractors__RailsSourceExtractor_gem_version -->|method_call| Gem__Specification_find_by_name_version
  Gem__Specification_find_by_name["Gem::Specification.find_by_name"]
  CodebaseIndex__Extractors__RailsSourceExtractor_gem_version -->|method_call| Gem__Specification_find_by_name
  CodebaseIndex__Extractors__RailsSourceExtractor_gem_version -->|method_call| Gem__Specification
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_framework_file["CodebaseIndex::Extractors::RailsSourceExtractor#extract_framework_file"]
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_framework_file -->|method_call| File
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_framework_file -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_framework_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_framework_file -->|method_call| Rails
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_gem_file["CodebaseIndex::Extractors::RailsSourceExtractor#extract_gem_file"]
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_gem_file -->|method_call| File
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_gem_file -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_gem_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_gem_file -->|method_call| Rails
  CodebaseIndex__Extractors__RailsSourceExtractor_annotate_framework_source["CodebaseIndex::Extractors::RailsSourceExtractor#annotate_framework_source"]
  CodebaseIndex__Extractors__RailsSourceExtractor_annotate_gem_source["CodebaseIndex::Extractors::RailsSourceExtractor#annotate_gem_source"]
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_module_names["CodebaseIndex::Extractors::RailsSourceExtractor#extract_module_names"]
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_class_names["CodebaseIndex::Extractors::RailsSourceExtractor#extract_class_names"]
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_public_api["CodebaseIndex::Extractors::RailsSourceExtractor#extract_public_api"]
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_public_api -->|method_call| Regexp
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_dsl_methods["CodebaseIndex::Extractors::RailsSourceExtractor#extract_dsl_methods"]
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_option_definitions["CodebaseIndex::Extractors::RailsSourceExtractor#extract_option_definitions"]
  CodebaseIndex__Extractors__RailsSourceExtractor_public_api_file_["CodebaseIndex::Extractors::RailsSourceExtractor#public_api_file?"]
  CodebaseIndex__Extractors__RailsSourceExtractor_rate_importance["CodebaseIndex::Extractors::RailsSourceExtractor#rate_importance"]
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_mixins["CodebaseIndex::Extractors::RailsSourceExtractor#extract_mixins"]
  CodebaseIndex__Extractors__RailsSourceExtractor_extract_configuration["CodebaseIndex::Extractors::RailsSourceExtractor#extract_configuration"]
  CodebaseIndex__Extractors__RakeTaskExtractor["CodebaseIndex::Extractors::RakeTaskExtractor"]
  CodebaseIndex__Extractors__RakeTaskExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__RakeTaskExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__RakeTaskExtractor_initialize["CodebaseIndex::Extractors::RakeTaskExtractor#initialize"]
  RAKE_DIRECTORIES_map["RAKE_DIRECTORIES.map"]
  CodebaseIndex__Extractors__RakeTaskExtractor_initialize -->|method_call| RAKE_DIRECTORIES_map
  RAKE_DIRECTORIES["RAKE_DIRECTORIES"]
  CodebaseIndex__Extractors__RakeTaskExtractor_initialize -->|method_call| RAKE_DIRECTORIES
  CodebaseIndex__Extractors__RakeTaskExtractor_initialize -->|method_call| Rails_root
  CodebaseIndex__Extractors__RakeTaskExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__RakeTaskExtractor_extract_all["CodebaseIndex::Extractors::RakeTaskExtractor#extract_all"]
  CodebaseIndex__Extractors__RakeTaskExtractor_extract_all -->|method_call| Dir___
  CodebaseIndex__Extractors__RakeTaskExtractor_extract_rake_file["CodebaseIndex::Extractors::RakeTaskExtractor#extract_rake_file"]
  CodebaseIndex__Extractors__RakeTaskExtractor_extract_rake_file -->|method_call| File
  CodebaseIndex__Extractors__RakeTaskExtractor_extract_rake_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__RakeTaskExtractor_extract_rake_file -->|method_call| Rails
  CodebaseIndex__Extractors__RakeTaskExtractor_parse_tasks["CodebaseIndex::Extractors::RakeTaskExtractor#parse_tasks"]
  CodebaseIndex__Extractors__RakeTaskExtractor_extract_namespace_name["CodebaseIndex::Extractors::RakeTaskExtractor#extract_namespace_name"]
  CodebaseIndex__Extractors__RakeTaskExtractor_extract_desc["CodebaseIndex::Extractors::RakeTaskExtractor#extract_desc"]
  CodebaseIndex__Extractors__RakeTaskExtractor_parse_task_line["CodebaseIndex::Extractors::RakeTaskExtractor#parse_task_line"]
  CodebaseIndex__Extractors__RakeTaskExtractor_parse_task_signature["CodebaseIndex::Extractors::RakeTaskExtractor#parse_task_signature"]
  CodebaseIndex__Extractors__RakeTaskExtractor_parse_task_signature -->|method_call| Regexp
  Regexp_last_match_scan["Regexp.last_match.scan"]
  CodebaseIndex__Extractors__RakeTaskExtractor_parse_task_signature -->|method_call| Regexp_last_match_scan
  CodebaseIndex__Extractors__RakeTaskExtractor_parse_task_signature -->|method_call| Regexp_last_match
  CodebaseIndex__Extractors__RakeTaskExtractor_parse_dependency_list["CodebaseIndex::Extractors::RakeTaskExtractor#parse_dependency_list"]
  CodebaseIndex__Extractors__RakeTaskExtractor_extract_task_block["CodebaseIndex::Extractors::RakeTaskExtractor#extract_task_block"]
  CodebaseIndex__Extractors__RakeTaskExtractor_block_opener_["CodebaseIndex::Extractors::RakeTaskExtractor#block_opener?"]
  CodebaseIndex__Extractors__RakeTaskExtractor_excluded_namespace_["CodebaseIndex::Extractors::RakeTaskExtractor#excluded_namespace?"]
  EXCLUDED_NAMESPACES["EXCLUDED_NAMESPACES"]
  CodebaseIndex__Extractors__RakeTaskExtractor_excluded_namespace_ -->|method_call| EXCLUDED_NAMESPACES
  CodebaseIndex__Extractors__RakeTaskExtractor_build_unit["CodebaseIndex::Extractors::RakeTaskExtractor#build_unit"]
  CodebaseIndex__Extractors__RakeTaskExtractor_build_unit -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__RakeTaskExtractor_build_source_annotation["CodebaseIndex::Extractors::RakeTaskExtractor#build_source_annotation"]
  CodebaseIndex__Extractors__RakeTaskExtractor_build_metadata["CodebaseIndex::Extractors::RakeTaskExtractor#build_metadata"]
  CodebaseIndex__Extractors__RakeTaskExtractor_extract_dependencies["CodebaseIndex::Extractors::RakeTaskExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__RouteExtractor["CodebaseIndex::Extractors::RouteExtractor"]
  CodebaseIndex__Extractors__RouteExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__RouteExtractor_initialize["CodebaseIndex::Extractors::RouteExtractor#initialize"]
  CodebaseIndex__Extractors__RouteExtractor_extract_all["CodebaseIndex::Extractors::RouteExtractor#extract_all"]
  Rails_application_routes["Rails.application.routes"]
  CodebaseIndex__Extractors__RouteExtractor_extract_all -->|method_call| Rails_application_routes
  CodebaseIndex__Extractors__RouteExtractor_extract_all -->|method_call| Rails_application
  CodebaseIndex__Extractors__RouteExtractor_extract_all -->|method_call| Rails
  CodebaseIndex__Extractors__RouteExtractor_rails_routes_available_["CodebaseIndex::Extractors::RouteExtractor#rails_routes_available?"]
  CodebaseIndex__Extractors__RouteExtractor_rails_routes_available_ -->|method_call| Rails
  CodebaseIndex__Extractors__RouteExtractor_rails_routes_available_ -->|method_call| Rails_application
  CodebaseIndex__Extractors__RouteExtractor_rails_routes_available_ -->|method_call| Rails_application_routes
  CodebaseIndex__Extractors__RouteExtractor_extract_route["CodebaseIndex::Extractors::RouteExtractor#extract_route"]
  CodebaseIndex__Extractors__RouteExtractor_extract_route -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__RouteExtractor_extract_route -->|method_call| Rails_logger
  CodebaseIndex__Extractors__RouteExtractor_extract_route -->|method_call| Rails
  CodebaseIndex__Extractors__RouteExtractor_route_defaults["CodebaseIndex::Extractors::RouteExtractor#route_defaults"]
  CodebaseIndex__Extractors__RouteExtractor_route_verb["CodebaseIndex::Extractors::RouteExtractor#route_verb"]
  CodebaseIndex__Extractors__RouteExtractor_route_path["CodebaseIndex::Extractors::RouteExtractor#route_path"]
  CodebaseIndex__Extractors__RouteExtractor_build_route_source["CodebaseIndex::Extractors::RouteExtractor#build_route_source"]
  CodebaseIndex__Extractors__RouteExtractor_build_route_metadata["CodebaseIndex::Extractors::RouteExtractor#build_route_metadata"]
  CodebaseIndex__Extractors__RouteExtractor_route_constraints["CodebaseIndex::Extractors::RouteExtractor#route_constraints"]
  CodebaseIndex__Extractors__RouteExtractor_build_route_dependencies["CodebaseIndex::Extractors::RouteExtractor#build_route_dependencies"]
  CodebaseIndex__Extractors__ScheduledJobExtractor["CodebaseIndex::Extractors::ScheduledJobExtractor"]
  CodebaseIndex__Extractors__ScheduledJobExtractor_initialize["CodebaseIndex::Extractors::ScheduledJobExtractor#initialize"]
  SCHEDULE_FILES["SCHEDULE_FILES"]
  CodebaseIndex__Extractors__ScheduledJobExtractor_initialize -->|method_call| SCHEDULE_FILES
  CodebaseIndex__Extractors__ScheduledJobExtractor_initialize -->|method_call| Rails_root
  CodebaseIndex__Extractors__ScheduledJobExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__ScheduledJobExtractor_initialize -->|method_call| File
  CodebaseIndex__Extractors__ScheduledJobExtractor_extract_all["CodebaseIndex::Extractors::ScheduledJobExtractor#extract_all"]
  CodebaseIndex__Extractors__ScheduledJobExtractor_extract_scheduled_job_file["CodebaseIndex::Extractors::ScheduledJobExtractor#extract_scheduled_job_file"]
  CodebaseIndex__Extractors__ScheduledJobExtractor_extract_scheduled_job_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__ScheduledJobExtractor_extract_scheduled_job_file -->|method_call| Rails
  CodebaseIndex__Extractors__ScheduledJobExtractor_extract_yaml_schedule["CodebaseIndex::Extractors::ScheduledJobExtractor#extract_yaml_schedule"]
  CodebaseIndex__Extractors__ScheduledJobExtractor_extract_yaml_schedule -->|method_call| File
  CodebaseIndex__Extractors__ScheduledJobExtractor_extract_yaml_schedule -->|method_call| YAML
  CodebaseIndex__Extractors__ScheduledJobExtractor_unwrap_environment_nesting["CodebaseIndex::Extractors::ScheduledJobExtractor#unwrap_environment_nesting"]
  ENVIRONMENT_KEYS["ENVIRONMENT_KEYS"]
  CodebaseIndex__Extractors__ScheduledJobExtractor_unwrap_environment_nesting -->|method_call| ENVIRONMENT_KEYS
  CodebaseIndex__Extractors__ScheduledJobExtractor_build_yaml_unit["CodebaseIndex::Extractors::ScheduledJobExtractor#build_yaml_unit"]
  CodebaseIndex__Extractors__ScheduledJobExtractor_build_yaml_unit -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__ScheduledJobExtractor_extract_cron["CodebaseIndex::Extractors::ScheduledJobExtractor#extract_cron"]
  CodebaseIndex__Extractors__ScheduledJobExtractor_extract_whenever_schedule["CodebaseIndex::Extractors::ScheduledJobExtractor#extract_whenever_schedule"]
  CodebaseIndex__Extractors__ScheduledJobExtractor_extract_whenever_schedule -->|method_call| File
  CodebaseIndex__Extractors__ScheduledJobExtractor_parse_whenever_blocks["CodebaseIndex::Extractors::ScheduledJobExtractor#parse_whenever_blocks"]
  CodebaseIndex__Extractors__ScheduledJobExtractor_detect_whenever_command["CodebaseIndex::Extractors::ScheduledJobExtractor#detect_whenever_command"]
  CodebaseIndex__Extractors__ScheduledJobExtractor_detect_whenever_command -->|method_call| Regexp
  CodebaseIndex__Extractors__ScheduledJobExtractor_extract_job_class_from_runner["CodebaseIndex::Extractors::ScheduledJobExtractor#extract_job_class_from_runner"]
  CodebaseIndex__Extractors__ScheduledJobExtractor_build_whenever_unit["CodebaseIndex::Extractors::ScheduledJobExtractor#build_whenever_unit"]
  CodebaseIndex__Extractors__ScheduledJobExtractor_build_whenever_unit -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__ScheduledJobExtractor_infer_format["CodebaseIndex::Extractors::ScheduledJobExtractor#infer_format"]
  CodebaseIndex__Extractors__ScheduledJobExtractor_infer_format -->|method_call| File
  CodebaseIndex__Extractors__ScheduledJobExtractor_infer_format -->|method_call| SCHEDULE_FILES
  CodebaseIndex__Extractors__ScheduledJobExtractor_build_dependencies["CodebaseIndex::Extractors::ScheduledJobExtractor#build_dependencies"]
  CodebaseIndex__Extractors__ScheduledJobExtractor_humanize_frequency["CodebaseIndex::Extractors::ScheduledJobExtractor#humanize_frequency"]
  CRON_HUMANIZE["CRON_HUMANIZE"]
  CodebaseIndex__Extractors__ScheduledJobExtractor_humanize_frequency -->|method_call| CRON_HUMANIZE
  CodebaseIndex__Extractors__SerializerExtractor["CodebaseIndex::Extractors::SerializerExtractor"]
  CodebaseIndex__Extractors__SerializerExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__SerializerExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__SerializerExtractor_initialize["CodebaseIndex::Extractors::SerializerExtractor#initialize"]
  SERIALIZER_DIRECTORIES_map["SERIALIZER_DIRECTORIES.map"]
  CodebaseIndex__Extractors__SerializerExtractor_initialize -->|method_call| SERIALIZER_DIRECTORIES_map
  SERIALIZER_DIRECTORIES["SERIALIZER_DIRECTORIES"]
  CodebaseIndex__Extractors__SerializerExtractor_initialize -->|method_call| SERIALIZER_DIRECTORIES
  CodebaseIndex__Extractors__SerializerExtractor_initialize -->|method_call| Rails_root
  CodebaseIndex__Extractors__SerializerExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__SerializerExtractor_extract_all["CodebaseIndex::Extractors::SerializerExtractor#extract_all"]
  CodebaseIndex__Extractors__SerializerExtractor_extract_all -->|method_call| Dir___
  BASE_CLASSES["BASE_CLASSES"]
  CodebaseIndex__Extractors__SerializerExtractor_extract_all -->|method_call| BASE_CLASSES
  CodebaseIndex__Extractors__SerializerExtractor_extract_serializer_file["CodebaseIndex::Extractors::SerializerExtractor#extract_serializer_file"]
  CodebaseIndex__Extractors__SerializerExtractor_extract_serializer_file -->|method_call| File
  CodebaseIndex__Extractors__SerializerExtractor_extract_serializer_file -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__SerializerExtractor_extract_serializer_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__SerializerExtractor_extract_serializer_file -->|method_call| Rails
  CodebaseIndex__Extractors__SerializerExtractor_extract_serializer_class["CodebaseIndex::Extractors::SerializerExtractor#extract_serializer_class"]
  CodebaseIndex__Extractors__SerializerExtractor_extract_serializer_class -->|method_call| File
  CodebaseIndex__Extractors__SerializerExtractor_extract_serializer_class -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__SerializerExtractor_extract_serializer_class -->|method_call| Rails_logger
  CodebaseIndex__Extractors__SerializerExtractor_extract_serializer_class -->|method_call| Rails
  CodebaseIndex__Extractors__SerializerExtractor_extract_class_name["CodebaseIndex::Extractors::SerializerExtractor#extract_class_name"]
  CodebaseIndex__Extractors__SerializerExtractor_extract_class_name -->|method_call| Regexp
  CodebaseIndex__Extractors__SerializerExtractor_serializer_file_["CodebaseIndex::Extractors::SerializerExtractor#serializer_file?"]
  CodebaseIndex__Extractors__SerializerExtractor_source_file_for["CodebaseIndex::Extractors::SerializerExtractor#source_file_for"]
  CodebaseIndex__Extractors__SerializerExtractor_source_file_for -->|method_call| Rails_root_join
  CodebaseIndex__Extractors__SerializerExtractor_source_file_for -->|method_call| Rails_root
  CodebaseIndex__Extractors__SerializerExtractor_source_file_for -->|method_call| Rails
  CodebaseIndex__Extractors__SerializerExtractor_annotate_source["CodebaseIndex::Extractors::SerializerExtractor#annotate_source"]
  CodebaseIndex__Extractors__SerializerExtractor_detect_serializer_type["CodebaseIndex::Extractors::SerializerExtractor#detect_serializer_type"]
  CodebaseIndex__Extractors__SerializerExtractor_detect_wrapped_model["CodebaseIndex::Extractors::SerializerExtractor#detect_wrapped_model"]
  CodebaseIndex__Extractors__SerializerExtractor_detect_wrapped_model -->|method_call| Regexp_last_match
  CodebaseIndex__Extractors__SerializerExtractor_detect_wrapped_model -->|method_call| Regexp
  CodebaseIndex__Extractors__SerializerExtractor_extract_metadata_from_source["CodebaseIndex::Extractors::SerializerExtractor#extract_metadata_from_source"]
  CodebaseIndex__Extractors__SerializerExtractor_extract_metadata_from_class["CodebaseIndex::Extractors::SerializerExtractor#extract_metadata_from_class"]
  CodebaseIndex__Extractors__SerializerExtractor_extract_attributes["CodebaseIndex::Extractors::SerializerExtractor#extract_attributes"]
  CodebaseIndex__Extractors__SerializerExtractor_extract_associations["CodebaseIndex::Extractors::SerializerExtractor#extract_associations"]
  CodebaseIndex__Extractors__SerializerExtractor_extract_custom_methods["CodebaseIndex::Extractors::SerializerExtractor#extract_custom_methods"]
  CodebaseIndex__Extractors__SerializerExtractor_extract_views["CodebaseIndex::Extractors::SerializerExtractor#extract_views"]
  CodebaseIndex__Extractors__SerializerExtractor_extract_dependencies["CodebaseIndex::Extractors::SerializerExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__ServiceExtractor["CodebaseIndex::Extractors::ServiceExtractor"]
  CodebaseIndex__Extractors__ServiceExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__ServiceExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__ServiceExtractor_initialize["CodebaseIndex::Extractors::ServiceExtractor#initialize"]
  SERVICE_DIRECTORIES_map["SERVICE_DIRECTORIES.map"]
  CodebaseIndex__Extractors__ServiceExtractor_initialize -->|method_call| SERVICE_DIRECTORIES_map
  SERVICE_DIRECTORIES["SERVICE_DIRECTORIES"]
  CodebaseIndex__Extractors__ServiceExtractor_initialize -->|method_call| SERVICE_DIRECTORIES
  CodebaseIndex__Extractors__ServiceExtractor_initialize -->|method_call| Rails_root
  CodebaseIndex__Extractors__ServiceExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__ServiceExtractor_extract_all["CodebaseIndex::Extractors::ServiceExtractor#extract_all"]
  CodebaseIndex__Extractors__ServiceExtractor_extract_all -->|method_call| Dir___
  CodebaseIndex__Extractors__ServiceExtractor_extract_service_file["CodebaseIndex::Extractors::ServiceExtractor#extract_service_file"]
  CodebaseIndex__Extractors__ServiceExtractor_extract_service_file -->|method_call| File
  CodebaseIndex__Extractors__ServiceExtractor_extract_service_file -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__ServiceExtractor_extract_service_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__ServiceExtractor_extract_service_file -->|method_call| Rails
  CodebaseIndex__Extractors__ServiceExtractor_extract_class_name["CodebaseIndex::Extractors::ServiceExtractor#extract_class_name"]
  CodebaseIndex__Extractors__ServiceExtractor_extract_class_name -->|method_call| Regexp
  CodebaseIndex__Extractors__ServiceExtractor_skip_file_["CodebaseIndex::Extractors::ServiceExtractor#skip_file?"]
  CodebaseIndex__Extractors__ServiceExtractor_annotate_source["CodebaseIndex::Extractors::ServiceExtractor#annotate_source"]
  CodebaseIndex__Extractors__ServiceExtractor_detect_entry_points["CodebaseIndex::Extractors::ServiceExtractor#detect_entry_points"]
  CodebaseIndex__Extractors__ServiceExtractor_extract_metadata["CodebaseIndex::Extractors::ServiceExtractor#extract_metadata"]
  CodebaseIndex__Extractors__ServiceExtractor_extract_injected_deps["CodebaseIndex::Extractors::ServiceExtractor#extract_injected_deps"]
  CodebaseIndex__Extractors__ServiceExtractor_extract_custom_errors["CodebaseIndex::Extractors::ServiceExtractor#extract_custom_errors"]
  CodebaseIndex__Extractors__ServiceExtractor_extract_rescue_handlers["CodebaseIndex::Extractors::ServiceExtractor#extract_rescue_handlers"]
  CodebaseIndex__Extractors__ServiceExtractor_infer_return_type["CodebaseIndex::Extractors::ServiceExtractor#infer_return_type"]
  CodebaseIndex__Extractors__ServiceExtractor_estimate_complexity["CodebaseIndex::Extractors::ServiceExtractor#estimate_complexity"]
  CodebaseIndex__Extractors__ServiceExtractor_infer_service_type["CodebaseIndex::Extractors::ServiceExtractor#infer_service_type"]
  CodebaseIndex__Extractors__ServiceExtractor_extract_dependencies["CodebaseIndex::Extractors::ServiceExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__SharedDependencyScanner["CodebaseIndex::Extractors::SharedDependencyScanner"]
  CodebaseIndex__Extractors__SharedDependencyScanner_scan_model_dependencies["CodebaseIndex::Extractors::SharedDependencyScanner#scan_model_dependencies"]
  CodebaseIndex__Extractors__SharedDependencyScanner_scan_service_dependencies["CodebaseIndex::Extractors::SharedDependencyScanner#scan_service_dependencies"]
  CodebaseIndex__Extractors__SharedDependencyScanner_scan_job_dependencies["CodebaseIndex::Extractors::SharedDependencyScanner#scan_job_dependencies"]
  CodebaseIndex__Extractors__SharedDependencyScanner_scan_mailer_dependencies["CodebaseIndex::Extractors::SharedDependencyScanner#scan_mailer_dependencies"]
  CodebaseIndex__Extractors__SharedDependencyScanner_scan_common_dependencies["CodebaseIndex::Extractors::SharedDependencyScanner#scan_common_dependencies"]
  CodebaseIndex__Extractors__SharedUtilityMethods["CodebaseIndex::Extractors::SharedUtilityMethods"]
  CodebaseIndex__Extractors__SharedUtilityMethods_extract_namespace["CodebaseIndex::Extractors::SharedUtilityMethods#extract_namespace"]
  CodebaseIndex__Extractors__SharedUtilityMethods_extract_public_methods["CodebaseIndex::Extractors::SharedUtilityMethods#extract_public_methods"]
  CodebaseIndex__Extractors__SharedUtilityMethods_extract_public_methods -->|method_call| Regexp
  CodebaseIndex__Extractors__SharedUtilityMethods_extract_class_methods["CodebaseIndex::Extractors::SharedUtilityMethods#extract_class_methods"]
  CodebaseIndex__Extractors__SharedUtilityMethods_extract_initialize_params["CodebaseIndex::Extractors::SharedUtilityMethods#extract_initialize_params"]
  CodebaseIndex__Extractors__StateMachineExtractor["CodebaseIndex::Extractors::StateMachineExtractor"]
  CodebaseIndex__Extractors__StateMachineExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__StateMachineExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__StateMachineExtractor_initialize["CodebaseIndex::Extractors::StateMachineExtractor#initialize"]
  MODEL_DIRECTORIES_map["MODEL_DIRECTORIES.map"]
  CodebaseIndex__Extractors__StateMachineExtractor_initialize -->|method_call| MODEL_DIRECTORIES_map
  MODEL_DIRECTORIES["MODEL_DIRECTORIES"]
  CodebaseIndex__Extractors__StateMachineExtractor_initialize -->|method_call| MODEL_DIRECTORIES
  CodebaseIndex__Extractors__StateMachineExtractor_initialize -->|method_call| Rails_root
  CodebaseIndex__Extractors__StateMachineExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__StateMachineExtractor_extract_all["CodebaseIndex::Extractors::StateMachineExtractor#extract_all"]
  CodebaseIndex__Extractors__StateMachineExtractor_extract_all -->|method_call| Dir___
  CodebaseIndex__Extractors__StateMachineExtractor_extract_model_file["CodebaseIndex::Extractors::StateMachineExtractor#extract_model_file"]
  CodebaseIndex__Extractors__StateMachineExtractor_extract_model_file -->|method_call| File
  CodebaseIndex__Extractors__StateMachineExtractor_extract_model_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__StateMachineExtractor_extract_model_file -->|method_call| Rails
  CodebaseIndex__Extractors__StateMachineExtractor_detect_class_name["CodebaseIndex::Extractors::StateMachineExtractor#detect_class_name"]
  CodebaseIndex__Extractors__StateMachineExtractor_detect_class_name -->|method_call| Regexp
  CodebaseIndex__Extractors__StateMachineExtractor_extract_aasm_units["CodebaseIndex::Extractors::StateMachineExtractor#extract_aasm_units"]
  CodebaseIndex__Extractors__StateMachineExtractor_parse_initial_state_aasm["CodebaseIndex::Extractors::StateMachineExtractor#parse_initial_state_aasm"]
  CodebaseIndex__Extractors__StateMachineExtractor_extract_statesman_units["CodebaseIndex::Extractors::StateMachineExtractor#extract_statesman_units"]
  CodebaseIndex__Extractors__StateMachineExtractor_parse_statesman_transitions["CodebaseIndex::Extractors::StateMachineExtractor#parse_statesman_transitions"]
  CodebaseIndex__Extractors__StateMachineExtractor_extract_state_machines_units["CodebaseIndex::Extractors::StateMachineExtractor#extract_state_machines_units"]
  CodebaseIndex__Extractors__StateMachineExtractor_extract_block_for_state_machine["CodebaseIndex::Extractors::StateMachineExtractor#extract_block_for_state_machine"]
  CodebaseIndex__Extractors__StateMachineExtractor_parse_state_machine_callbacks["CodebaseIndex::Extractors::StateMachineExtractor#parse_state_machine_callbacks"]
  CodebaseIndex__Extractors__StateMachineExtractor_parse_events_from_source["CodebaseIndex::Extractors::StateMachineExtractor#parse_events_from_source"]
  CodebaseIndex__Extractors__StateMachineExtractor_parse_transition_line["CodebaseIndex::Extractors::StateMachineExtractor#parse_transition_line"]
  CodebaseIndex__Extractors__StateMachineExtractor_block_opener_["CodebaseIndex::Extractors::StateMachineExtractor#block_opener?"]
  CodebaseIndex__Extractors__StateMachineExtractor_build_unit["CodebaseIndex::Extractors::StateMachineExtractor#build_unit"]
  CodebaseIndex__Extractors__StateMachineExtractor_build_unit -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__StateMachineExtractor_build_dependencies["CodebaseIndex::Extractors::StateMachineExtractor#build_dependencies"]
  CodebaseIndex__Extractors__TestMappingExtractor["CodebaseIndex::Extractors::TestMappingExtractor"]
  CodebaseIndex__Extractors__TestMappingExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__TestMappingExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__TestMappingExtractor_initialize["CodebaseIndex::Extractors::TestMappingExtractor#initialize"]
  CodebaseIndex__Extractors__TestMappingExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__TestMappingExtractor_extract_all["CodebaseIndex::Extractors::TestMappingExtractor#extract_all"]
  CodebaseIndex__Extractors__TestMappingExtractor_extract_test_file["CodebaseIndex::Extractors::TestMappingExtractor#extract_test_file"]
  CodebaseIndex__Extractors__TestMappingExtractor_extract_test_file -->|method_call| File
  CodebaseIndex__Extractors__TestMappingExtractor_extract_test_file -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__TestMappingExtractor_extract_test_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__TestMappingExtractor_extract_test_file -->|method_call| Rails
  CodebaseIndex__Extractors__TestMappingExtractor_rspec_units["CodebaseIndex::Extractors::TestMappingExtractor#rspec_units"]
  CodebaseIndex__Extractors__TestMappingExtractor_rspec_units -->|method_call| Dir___
  CodebaseIndex__Extractors__TestMappingExtractor_minitest_units["CodebaseIndex::Extractors::TestMappingExtractor#minitest_units"]
  CodebaseIndex__Extractors__TestMappingExtractor_minitest_units -->|method_call| Dir___
  CodebaseIndex__Extractors__TestMappingExtractor_detect_framework["CodebaseIndex::Extractors::TestMappingExtractor#detect_framework"]
  CodebaseIndex__Extractors__TestMappingExtractor_extract_metadata["CodebaseIndex::Extractors::TestMappingExtractor#extract_metadata"]
  CodebaseIndex__Extractors__TestMappingExtractor_extract_subject_class["CodebaseIndex::Extractors::TestMappingExtractor#extract_subject_class"]
  CodebaseIndex__Extractors__TestMappingExtractor_extract_rspec_subject["CodebaseIndex::Extractors::TestMappingExtractor#extract_rspec_subject"]
  CodebaseIndex__Extractors__TestMappingExtractor_extract_minitest_subject["CodebaseIndex::Extractors::TestMappingExtractor#extract_minitest_subject"]
  CodebaseIndex__Extractors__TestMappingExtractor_count_tests["CodebaseIndex::Extractors::TestMappingExtractor#count_tests"]
  CodebaseIndex__Extractors__TestMappingExtractor_extract_shared_examples_defined["CodebaseIndex::Extractors::TestMappingExtractor#extract_shared_examples_defined"]
  CodebaseIndex__Extractors__TestMappingExtractor_extract_shared_examples_used["CodebaseIndex::Extractors::TestMappingExtractor#extract_shared_examples_used"]
  CodebaseIndex__Extractors__TestMappingExtractor_infer_test_type["CodebaseIndex::Extractors::TestMappingExtractor#infer_test_type"]
  CodebaseIndex__Extractors__TestMappingExtractor_extract_dependencies["CodebaseIndex::Extractors::TestMappingExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__TestMappingExtractor_infer_type_from_test_type["CodebaseIndex::Extractors::TestMappingExtractor#infer_type_from_test_type"]
  CodebaseIndex__Extractors__ValidatorExtractor["CodebaseIndex::Extractors::ValidatorExtractor"]
  CodebaseIndex__Extractors__ValidatorExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__ValidatorExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__ValidatorExtractor_initialize["CodebaseIndex::Extractors::ValidatorExtractor#initialize"]
  VALIDATOR_DIRECTORIES_map["VALIDATOR_DIRECTORIES.map"]
  CodebaseIndex__Extractors__ValidatorExtractor_initialize -->|method_call| VALIDATOR_DIRECTORIES_map
  VALIDATOR_DIRECTORIES["VALIDATOR_DIRECTORIES"]
  CodebaseIndex__Extractors__ValidatorExtractor_initialize -->|method_call| VALIDATOR_DIRECTORIES
  CodebaseIndex__Extractors__ValidatorExtractor_initialize -->|method_call| Rails_root
  CodebaseIndex__Extractors__ValidatorExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__ValidatorExtractor_extract_all["CodebaseIndex::Extractors::ValidatorExtractor#extract_all"]
  CodebaseIndex__Extractors__ValidatorExtractor_extract_all -->|method_call| Dir___
  CodebaseIndex__Extractors__ValidatorExtractor_extract_validator_file["CodebaseIndex::Extractors::ValidatorExtractor#extract_validator_file"]
  CodebaseIndex__Extractors__ValidatorExtractor_extract_validator_file -->|method_call| File
  CodebaseIndex__Extractors__ValidatorExtractor_extract_validator_file -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__ValidatorExtractor_extract_validator_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__ValidatorExtractor_extract_validator_file -->|method_call| Rails
  CodebaseIndex__Extractors__ValidatorExtractor_extract_class_name["CodebaseIndex::Extractors::ValidatorExtractor#extract_class_name"]
  CodebaseIndex__Extractors__ValidatorExtractor_extract_class_name -->|method_call| Regexp
  CodebaseIndex__Extractors__ValidatorExtractor_validator_file_["CodebaseIndex::Extractors::ValidatorExtractor#validator_file?"]
  CodebaseIndex__Extractors__ValidatorExtractor_annotate_source["CodebaseIndex::Extractors::ValidatorExtractor#annotate_source"]
  CodebaseIndex__Extractors__ValidatorExtractor_extract_metadata["CodebaseIndex::Extractors::ValidatorExtractor#extract_metadata"]
  CodebaseIndex__Extractors__ValidatorExtractor_detect_validator_type["CodebaseIndex::Extractors::ValidatorExtractor#detect_validator_type"]
  CodebaseIndex__Extractors__ValidatorExtractor_extract_validated_attributes["CodebaseIndex::Extractors::ValidatorExtractor#extract_validated_attributes"]
  CodebaseIndex__Extractors__ValidatorExtractor_extract_validation_rules["CodebaseIndex::Extractors::ValidatorExtractor#extract_validation_rules"]
  CodebaseIndex__Extractors__ValidatorExtractor_extract_error_messages["CodebaseIndex::Extractors::ValidatorExtractor#extract_error_messages"]
  CodebaseIndex__Extractors__ValidatorExtractor_extract_options["CodebaseIndex::Extractors::ValidatorExtractor#extract_options"]
  CodebaseIndex__Extractors__ValidatorExtractor_infer_models_from_name["CodebaseIndex::Extractors::ValidatorExtractor#infer_models_from_name"]
  CodebaseIndex__Extractors__ValidatorExtractor_extract_custom_errors["CodebaseIndex::Extractors::ValidatorExtractor#extract_custom_errors"]
  CodebaseIndex__Extractors__ValidatorExtractor_extract_dependencies["CodebaseIndex::Extractors::ValidatorExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__ViewComponentExtractor["CodebaseIndex::Extractors::ViewComponentExtractor"]
  CodebaseIndex__Extractors__ViewComponentExtractor -->|include| SharedUtilityMethods
  CodebaseIndex__Extractors__ViewComponentExtractor -->|include| SharedDependencyScanner
  CodebaseIndex__Extractors__ViewComponentExtractor_initialize["CodebaseIndex::Extractors::ViewComponentExtractor#initialize"]
  CodebaseIndex__Extractors__ViewComponentExtractor_extract_all["CodebaseIndex::Extractors::ViewComponentExtractor#extract_all"]
  CodebaseIndex__Extractors__ViewComponentExtractor_extract_component["CodebaseIndex::Extractors::ViewComponentExtractor#extract_component"]
  CodebaseIndex__Extractors__ViewComponentExtractor_extract_component -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__ViewComponentExtractor_extract_component -->|method_call| Rails_logger
  CodebaseIndex__Extractors__ViewComponentExtractor_extract_component -->|method_call| Rails
  CodebaseIndex__Extractors__ViewComponentExtractor_find_component_base["CodebaseIndex::Extractors::ViewComponentExtractor#find_component_base"]
  CodebaseIndex__Extractors__ViewComponentExtractor_preview_class_["CodebaseIndex::Extractors::ViewComponentExtractor#preview_class?"]
  CodebaseIndex__Extractors__ViewComponentExtractor_source_file_for["CodebaseIndex::Extractors::ViewComponentExtractor#source_file_for"]
  CodebaseIndex__Extractors__ViewComponentExtractor_source_file_for -->|method_call| Rails_root
  CodebaseIndex__Extractors__ViewComponentExtractor_source_file_for -->|method_call| Rails
  CodebaseIndex__Extractors__ViewComponentExtractor_source_file_for -->|method_call| File
  CodebaseIndex__Extractors__ViewComponentExtractor_read_source["CodebaseIndex::Extractors::ViewComponentExtractor#read_source"]
  CodebaseIndex__Extractors__ViewComponentExtractor_read_source -->|method_call| File
  CodebaseIndex__Extractors__ViewComponentExtractor_extract_metadata["CodebaseIndex::Extractors::ViewComponentExtractor#extract_metadata"]
  CodebaseIndex__Extractors__ViewComponentExtractor_extract_slots["CodebaseIndex::Extractors::ViewComponentExtractor#extract_slots"]
  CodebaseIndex__Extractors__ViewComponentExtractor_extract_renders_many["CodebaseIndex::Extractors::ViewComponentExtractor#extract_renders_many"]
  CodebaseIndex__Extractors__ViewComponentExtractor_extract_renders_one["CodebaseIndex::Extractors::ViewComponentExtractor#extract_renders_one"]
  CodebaseIndex__Extractors__ViewComponentExtractor_extract_initialize_params["CodebaseIndex::Extractors::ViewComponentExtractor#extract_initialize_params"]
  CodebaseIndex__Extractors__ViewComponentExtractor_detect_sidecar_template["CodebaseIndex::Extractors::ViewComponentExtractor#detect_sidecar_template"]
  CodebaseIndex__Extractors__ViewComponentExtractor_detect_sidecar_template -->|method_call| Rails_root
  CodebaseIndex__Extractors__ViewComponentExtractor_detect_sidecar_template -->|method_call| Rails
  CodebaseIndex__Extractors__ViewComponentExtractor_detect_sidecar_template -->|method_call| File
  CodebaseIndex__Extractors__ViewComponentExtractor_detect_preview_class["CodebaseIndex::Extractors::ViewComponentExtractor#detect_preview_class"]
  CodebaseIndex__Extractors__ViewComponentExtractor_detect_collection_support["CodebaseIndex::Extractors::ViewComponentExtractor#detect_collection_support"]
  CodebaseIndex__Extractors__ViewComponentExtractor_extract_callbacks["CodebaseIndex::Extractors::ViewComponentExtractor#extract_callbacks"]
  CodebaseIndex__Extractors__ViewComponentExtractor_extract_content_areas["CodebaseIndex::Extractors::ViewComponentExtractor#extract_content_areas"]
  CodebaseIndex__Extractors__ViewComponentExtractor_extract_dependencies["CodebaseIndex::Extractors::ViewComponentExtractor#extract_dependencies"]
  CodebaseIndex__Extractors__ViewTemplateExtractor["CodebaseIndex::Extractors::ViewTemplateExtractor"]
  CodebaseIndex__Extractors__ViewTemplateExtractor_initialize["CodebaseIndex::Extractors::ViewTemplateExtractor#initialize"]
  VIEW_DIRECTORIES_map["VIEW_DIRECTORIES.map"]
  CodebaseIndex__Extractors__ViewTemplateExtractor_initialize -->|method_call| VIEW_DIRECTORIES_map
  VIEW_DIRECTORIES["VIEW_DIRECTORIES"]
  CodebaseIndex__Extractors__ViewTemplateExtractor_initialize -->|method_call| VIEW_DIRECTORIES
  CodebaseIndex__Extractors__ViewTemplateExtractor_initialize -->|method_call| Rails_root
  CodebaseIndex__Extractors__ViewTemplateExtractor_initialize -->|method_call| Rails
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_all["CodebaseIndex::Extractors::ViewTemplateExtractor#extract_all"]
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_all -->|method_call| Dir___
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_all -->|method_call| Dir
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_view_template_file["CodebaseIndex::Extractors::ViewTemplateExtractor#extract_view_template_file"]
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_view_template_file -->|method_call| File
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_view_template_file -->|method_call| ExtractedUnit
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_view_template_file -->|method_call| Rails_logger
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_view_template_file -->|method_call| Rails
  CodebaseIndex__Extractors__ViewTemplateExtractor_build_identifier["CodebaseIndex::Extractors::ViewTemplateExtractor#build_identifier"]
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_view_namespace["CodebaseIndex::Extractors::ViewTemplateExtractor#extract_view_namespace"]
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_view_namespace -->|method_call| File
  CodebaseIndex__Extractors__ViewTemplateExtractor_build_metadata["CodebaseIndex::Extractors::ViewTemplateExtractor#build_metadata"]
  CodebaseIndex__Extractors__ViewTemplateExtractor_partial_["CodebaseIndex::Extractors::ViewTemplateExtractor#partial?"]
  CodebaseIndex__Extractors__ViewTemplateExtractor_partial_ -->|method_call| File_basename
  CodebaseIndex__Extractors__ViewTemplateExtractor_partial_ -->|method_call| File
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_rendered_partials["CodebaseIndex::Extractors::ViewTemplateExtractor#extract_rendered_partials"]
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_rendered_partials -->|method_call| Set
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_instance_variables["CodebaseIndex::Extractors::ViewTemplateExtractor#extract_instance_variables"]
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_helpers["CodebaseIndex::Extractors::ViewTemplateExtractor#extract_helpers"]
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_helpers -->|method_call| Set
  COMMON_HELPERS["COMMON_HELPERS"]
  CodebaseIndex__Extractors__ViewTemplateExtractor_extract_helpers -->|method_call| COMMON_HELPERS
  CodebaseIndex__Extractors__ViewTemplateExtractor_build_dependencies["CodebaseIndex::Extractors::ViewTemplateExtractor#build_dependencies"]
  CodebaseIndex__Extractors__ViewTemplateExtractor_resolve_partial_identifier["CodebaseIndex::Extractors::ViewTemplateExtractor#resolve_partial_identifier"]
  CodebaseIndex__Extractors__ViewTemplateExtractor_resolve_partial_identifier -->|method_call| File
  CodebaseIndex__Extractors__ViewTemplateExtractor_infer_controller["CodebaseIndex::Extractors::ViewTemplateExtractor#infer_controller"]
  CodebaseIndex__Feedback["CodebaseIndex::Feedback"]
  CodebaseIndex__Feedback__GapDetector["CodebaseIndex::Feedback::GapDetector"]
  CodebaseIndex__Feedback__GapDetector_initialize["CodebaseIndex::Feedback::GapDetector#initialize"]
  CodebaseIndex__Feedback__GapDetector_detect["CodebaseIndex::Feedback::GapDetector#detect"]
  CodebaseIndex__Feedback__GapDetector_detect_low_score_patterns["CodebaseIndex::Feedback::GapDetector#detect_low_score_patterns"]
  CodebaseIndex__Feedback__GapDetector_count_keywords["CodebaseIndex::Feedback::GapDetector#count_keywords"]
  CodebaseIndex__Feedback__GapDetector_count_keywords -->|method_call| Hash
  CodebaseIndex__Feedback__GapDetector_detect_frequently_missing["CodebaseIndex::Feedback::GapDetector#detect_frequently_missing"]
  CodebaseIndex__Feedback__GapDetector_detect_frequently_missing -->|method_call| Hash
  CodebaseIndex__Feedback__Store["CodebaseIndex::Feedback::Store"]
  CodebaseIndex__Feedback__Store_initialize["CodebaseIndex::Feedback::Store#initialize"]
  CodebaseIndex__Feedback__Store_record_rating["CodebaseIndex::Feedback::Store#record_rating"]
  CodebaseIndex__Feedback__Store_record_gap["CodebaseIndex::Feedback::Store#record_gap"]
  CodebaseIndex__Feedback__Store_all_entries["CodebaseIndex::Feedback::Store#all_entries"]
  CodebaseIndex__Feedback__Store_all_entries -->|method_call| File
  CodebaseIndex__Feedback__Store_all_entries -->|method_call| JSON
  CodebaseIndex__Feedback__Store_ratings["CodebaseIndex::Feedback::Store#ratings"]
  CodebaseIndex__Feedback__Store_gaps["CodebaseIndex::Feedback::Store#gaps"]
  CodebaseIndex__Feedback__Store_average_score["CodebaseIndex::Feedback::Store#average_score"]
  CodebaseIndex__Feedback__Store_append["CodebaseIndex::Feedback::Store#append"]
  CodebaseIndex__Feedback__Store_append -->|method_call| FileUtils
  CodebaseIndex__Feedback__Store_append -->|method_call| File
  CodebaseIndex__FlowAnalysis["CodebaseIndex::FlowAnalysis"]
  CodebaseIndex__FlowAnalysis__OperationExtractor["CodebaseIndex::FlowAnalysis::OperationExtractor"]
  CodebaseIndex__FlowAnalysis__OperationExtractor_extract["CodebaseIndex::FlowAnalysis::OperationExtractor#extract"]
  CodebaseIndex__FlowAnalysis__OperationExtractor_walk["CodebaseIndex::FlowAnalysis::OperationExtractor#walk"]
  CodebaseIndex__FlowAnalysis__OperationExtractor_walk_children["CodebaseIndex::FlowAnalysis::OperationExtractor#walk_children"]
  CodebaseIndex__FlowAnalysis__OperationExtractor_handle_block["CodebaseIndex::FlowAnalysis::OperationExtractor#handle_block"]
  CodebaseIndex__FlowAnalysis__OperationExtractor_handle_send["CodebaseIndex::FlowAnalysis::OperationExtractor#handle_send"]
  CodebaseIndex__FlowAnalysis__OperationExtractor_handle_conditional["CodebaseIndex::FlowAnalysis::OperationExtractor#handle_conditional"]
  CodebaseIndex__FlowAnalysis__OperationExtractor_handle_case["CodebaseIndex::FlowAnalysis::OperationExtractor#handle_case"]
  CodebaseIndex__FlowAnalysis__OperationExtractor_transaction_call_["CodebaseIndex::FlowAnalysis::OperationExtractor#transaction_call?"]
  TRANSACTION_METHODS["TRANSACTION_METHODS"]
  CodebaseIndex__FlowAnalysis__OperationExtractor_transaction_call_ -->|method_call| TRANSACTION_METHODS
  CodebaseIndex__FlowAnalysis__OperationExtractor_async_call_["CodebaseIndex::FlowAnalysis::OperationExtractor#async_call?"]
  CodebaseIndex__FlowAnalysis__OperationExtractor_async_call_ -->|method_call| ASYNC_METHODS
  CodebaseIndex__FlowAnalysis__OperationExtractor_response_call_["CodebaseIndex::FlowAnalysis::OperationExtractor#response_call?"]
  RESPONSE_METHODS["RESPONSE_METHODS"]
  CodebaseIndex__FlowAnalysis__OperationExtractor_response_call_ -->|method_call| RESPONSE_METHODS
  CodebaseIndex__FlowAnalysis__OperationExtractor_dynamic_dispatch_["CodebaseIndex::FlowAnalysis::OperationExtractor#dynamic_dispatch?"]
  DYNAMIC_DISPATCH_METHODS["DYNAMIC_DISPATCH_METHODS"]
  CodebaseIndex__FlowAnalysis__OperationExtractor_dynamic_dispatch_ -->|method_call| DYNAMIC_DISPATCH_METHODS
  CodebaseIndex__FlowAnalysis__OperationExtractor_significant_call_["CodebaseIndex::FlowAnalysis::OperationExtractor#significant_call?"]
  Ast__INSIGNIFICANT_METHODS["Ast::INSIGNIFICANT_METHODS"]
  CodebaseIndex__FlowAnalysis__OperationExtractor_significant_call_ -->|method_call| Ast__INSIGNIFICANT_METHODS
  CodebaseIndex__FlowAnalysis__ResponseCodeMapper["CodebaseIndex::FlowAnalysis::ResponseCodeMapper"]
  CodebaseIndex__FlowAnalysis__ResponseCodeMapper_resolve_method["CodebaseIndex::FlowAnalysis::ResponseCodeMapper.resolve_method"]
  STATUS_CODES["STATUS_CODES"]
  CodebaseIndex__FlowAnalysis__ResponseCodeMapper_resolve_method -->|method_call| STATUS_CODES
  CodebaseIndex__FlowAnalysis__ResponseCodeMapper_resolve_status["CodebaseIndex::FlowAnalysis::ResponseCodeMapper.resolve_status"]
  CodebaseIndex__FlowAnalysis__ResponseCodeMapper_resolve_status -->|method_call| STATUS_CODES
  CodebaseIndex__FlowAnalysis__ResponseCodeMapper_extract_status_from_args["CodebaseIndex::FlowAnalysis::ResponseCodeMapper.extract_status_from_args"]
  CodebaseIndex__FlowAssembler["CodebaseIndex::FlowAssembler"]
  CodebaseIndex__FlowAssembler_initialize["CodebaseIndex::FlowAssembler#initialize"]
  CodebaseIndex__FlowAssembler_initialize -->|method_call| Ast__Parser
  CodebaseIndex__FlowAssembler_initialize -->|method_call| Ast__MethodExtractor
  CodebaseIndex__FlowAssembler_initialize -->|method_call| FlowAnalysis__OperationExtractor
  CodebaseIndex__FlowAssembler_assemble["CodebaseIndex::FlowAssembler#assemble"]
  CodebaseIndex__FlowAssembler_assemble -->|method_call| Set
  FlowDocument["FlowDocument"]
  CodebaseIndex__FlowAssembler_assemble -->|method_call| FlowDocument
  CodebaseIndex__FlowAssembler_expand["CodebaseIndex::FlowAssembler#expand"]
  CodebaseIndex__FlowAssembler_extract_operations["CodebaseIndex::FlowAssembler#extract_operations"]
  CodebaseIndex__FlowAssembler_prepend_callbacks["CodebaseIndex::FlowAssembler#prepend_callbacks"]
  CodebaseIndex__FlowAssembler_expand_operation["CodebaseIndex::FlowAssembler#expand_operation"]
  CodebaseIndex__FlowAssembler_resolve_target["CodebaseIndex::FlowAssembler#resolve_target"]
  CodebaseIndex__FlowAssembler_parse_identifier["CodebaseIndex::FlowAssembler#parse_identifier"]
  CodebaseIndex__FlowAssembler_load_unit["CodebaseIndex::FlowAssembler#load_unit"]
  CodebaseIndex__FlowAssembler_load_unit -->|method_call| Dir___
  CodebaseIndex__FlowAssembler_load_unit -->|method_call| JSON
  CodebaseIndex__FlowAssembler_extract_route["CodebaseIndex::FlowAssembler#extract_route"]
  CodebaseIndex__FlowDocument["CodebaseIndex::FlowDocument"]
  CodebaseIndex__FlowDocument_initialize["CodebaseIndex::FlowDocument#initialize"]
  CodebaseIndex__FlowDocument_initialize -->|method_call| Time_now
  CodebaseIndex__FlowDocument_initialize -->|method_call| Time
  CodebaseIndex__FlowDocument_to_h["CodebaseIndex::FlowDocument#to_h"]
  CodebaseIndex__FlowDocument_from_h["CodebaseIndex::FlowDocument.from_h"]
  CodebaseIndex__FlowDocument_deep_symbolize_keys["CodebaseIndex::FlowDocument.deep_symbolize_keys"]
  CodebaseIndex__FlowDocument_to_markdown["CodebaseIndex::FlowDocument#to_markdown"]
  CodebaseIndex__FlowDocument_format_header["CodebaseIndex::FlowDocument#format_header"]
  CodebaseIndex__FlowDocument_format_step["CodebaseIndex::FlowDocument#format_step"]
  CodebaseIndex__FlowDocument_format_operations["CodebaseIndex::FlowDocument#format_operations"]
  CodebaseIndex__FlowPrecomputer["CodebaseIndex::FlowPrecomputer"]
  CodebaseIndex__FlowPrecomputer_initialize["CodebaseIndex::FlowPrecomputer#initialize"]
  CodebaseIndex__FlowPrecomputer_initialize -->|method_call| File
  CodebaseIndex__FlowPrecomputer_precompute["CodebaseIndex::FlowPrecomputer#precompute"]
  CodebaseIndex__FlowPrecomputer_precompute -->|method_call| FileUtils
  FlowAssembler["FlowAssembler"]
  CodebaseIndex__FlowPrecomputer_precompute -->|method_call| FlowAssembler
  CodebaseIndex__FlowPrecomputer_controller_units["CodebaseIndex::FlowPrecomputer#controller_units"]
  CodebaseIndex__FlowPrecomputer_assemble_and_write["CodebaseIndex::FlowPrecomputer#assemble_and_write"]
  CodebaseIndex__FlowPrecomputer_assemble_and_write -->|method_call| File
  CodebaseIndex__FlowPrecomputer_assemble_and_write -->|method_call| Rails_logger
  CodebaseIndex__FlowPrecomputer_assemble_and_write -->|method_call| Rails
  CodebaseIndex__FlowPrecomputer_write_flow_index["CodebaseIndex::FlowPrecomputer#write_flow_index"]
  CodebaseIndex__FlowPrecomputer_write_flow_index -->|method_call| File
  CodebaseIndex__Formatting["CodebaseIndex::Formatting"]
  CodebaseIndex__Formatting__Base["CodebaseIndex::Formatting::Base"]
  CodebaseIndex__Formatting__Base_format["CodebaseIndex::Formatting::Base#format"]
  CodebaseIndex__Formatting__Base_estimate_tokens["CodebaseIndex::Formatting::Base#estimate_tokens"]
  CodebaseIndex__Formatting__ClaudeAdapter["CodebaseIndex::Formatting::ClaudeAdapter"]
  Base["Base"]
  CodebaseIndex__Formatting__ClaudeAdapter -->|inheritance| Base
  CodebaseIndex__Formatting__ClaudeAdapter_format["CodebaseIndex::Formatting::ClaudeAdapter#format"]
  CodebaseIndex__Formatting__ClaudeAdapter_format_content["CodebaseIndex::Formatting::ClaudeAdapter#format_content"]
  CodebaseIndex__Formatting__ClaudeAdapter_format_sources["CodebaseIndex::Formatting::ClaudeAdapter#format_sources"]
  CodebaseIndex__Formatting__ClaudeAdapter_source_attributes["CodebaseIndex::Formatting::ClaudeAdapter#source_attributes"]
  CodebaseIndex__Formatting__ClaudeAdapter_indent["CodebaseIndex::Formatting::ClaudeAdapter#indent"]
  CodebaseIndex__Formatting__ClaudeAdapter_escape_xml["CodebaseIndex::Formatting::ClaudeAdapter#escape_xml"]
  CodebaseIndex__Formatting__GenericAdapter["CodebaseIndex::Formatting::GenericAdapter"]
  CodebaseIndex__Formatting__GenericAdapter -->|inheritance| Base
  CodebaseIndex__Formatting__GenericAdapter_format["CodebaseIndex::Formatting::GenericAdapter#format"]
  CodebaseIndex__Formatting__GenericAdapter_format_sources["CodebaseIndex::Formatting::GenericAdapter#format_sources"]
  CodebaseIndex__Formatting__GptAdapter["CodebaseIndex::Formatting::GptAdapter"]
  CodebaseIndex__Formatting__GptAdapter -->|inheritance| Base
  CodebaseIndex__Formatting__GptAdapter_format["CodebaseIndex::Formatting::GptAdapter#format"]
  CodebaseIndex__Formatting__GptAdapter_format_sources["CodebaseIndex::Formatting::GptAdapter#format_sources"]
  CodebaseIndex__Formatting__HumanAdapter["CodebaseIndex::Formatting::HumanAdapter"]
  CodebaseIndex__Formatting__HumanAdapter -->|inheritance| Base
  CodebaseIndex__Formatting__HumanAdapter_format["CodebaseIndex::Formatting::HumanAdapter#format"]
  CodebaseIndex__Formatting__HumanAdapter_format_header["CodebaseIndex::Formatting::HumanAdapter#format_header"]
  CodebaseIndex__Formatting__HumanAdapter_format_sources["CodebaseIndex::Formatting::HumanAdapter#format_sources"]
  CodebaseIndex__Formatting__HumanAdapter_format_source_entry["CodebaseIndex::Formatting::HumanAdapter#format_source_entry"]
  CodebaseIndex__GraphAnalyzer["CodebaseIndex::GraphAnalyzer"]
  CodebaseIndex__GraphAnalyzer_initialize["CodebaseIndex::GraphAnalyzer#initialize"]
  CodebaseIndex__GraphAnalyzer_orphans["CodebaseIndex::GraphAnalyzer#orphans"]
  EXCLUDED_ORPHAN_TYPES["EXCLUDED_ORPHAN_TYPES"]
  CodebaseIndex__GraphAnalyzer_orphans -->|method_call| EXCLUDED_ORPHAN_TYPES
  CodebaseIndex__GraphAnalyzer_dead_ends["CodebaseIndex::GraphAnalyzer#dead_ends"]
  CodebaseIndex__GraphAnalyzer_hubs["CodebaseIndex::GraphAnalyzer#hubs"]
  CodebaseIndex__GraphAnalyzer_cycles["CodebaseIndex::GraphAnalyzer#cycles"]
  CodebaseIndex__GraphAnalyzer_bridges["CodebaseIndex::GraphAnalyzer#bridges"]
  CodebaseIndex__GraphAnalyzer_bridges -->|method_call| Hash
  Random["Random"]
  CodebaseIndex__GraphAnalyzer_bridges -->|method_call| Random
  CodebaseIndex__GraphAnalyzer_analyze["CodebaseIndex::GraphAnalyzer#analyze"]
  CodebaseIndex__GraphAnalyzer_graph_data["CodebaseIndex::GraphAnalyzer#graph_data"]
  CodebaseIndex__GraphAnalyzer_graph_nodes["CodebaseIndex::GraphAnalyzer#graph_nodes"]
  CodebaseIndex__GraphAnalyzer_graph_edges["CodebaseIndex::GraphAnalyzer#graph_edges"]
  CodebaseIndex__GraphAnalyzer_detect_cycles["CodebaseIndex::GraphAnalyzer#detect_cycles"]
  CodebaseIndex__GraphAnalyzer_detect_cycles -->|method_call| Hash
  CodebaseIndex__GraphAnalyzer_detect_cycles -->|method_call| Set
  CodebaseIndex__GraphAnalyzer_extract_cycle_from_path["CodebaseIndex::GraphAnalyzer#extract_cycle_from_path"]
  CodebaseIndex__GraphAnalyzer_normalize_cycle_signature["CodebaseIndex::GraphAnalyzer#normalize_cycle_signature"]
  CodebaseIndex__GraphAnalyzer_generate_sample_pairs["CodebaseIndex::GraphAnalyzer#generate_sample_pairs"]
  CodebaseIndex__GraphAnalyzer_generate_sample_pairs -->|method_call| Set
  CodebaseIndex__GraphAnalyzer_bfs_shortest_path["CodebaseIndex::GraphAnalyzer#bfs_shortest_path"]
  CodebaseIndex__GraphAnalyzer_bfs_shortest_path -->|method_call| Set
  CodebaseIndex__MCP["CodebaseIndex::MCP"]
  CodebaseIndex__MCP__IndexReader["CodebaseIndex::MCP::IndexReader"]
  CodebaseIndex__MCP__IndexReader_initialize["CodebaseIndex::MCP::IndexReader#initialize"]
  CodebaseIndex__MCP__IndexReader_initialize -->|method_call| Pathname
  CodebaseIndex__MCP__IndexReader_reload_["CodebaseIndex::MCP::IndexReader#reload!"]
  CodebaseIndex__MCP__IndexReader_manifest["CodebaseIndex::MCP::IndexReader#manifest"]
  CodebaseIndex__MCP__IndexReader_summary["CodebaseIndex::MCP::IndexReader#summary"]
  CodebaseIndex__MCP__IndexReader_dependency_graph["CodebaseIndex::MCP::IndexReader#dependency_graph"]
  CodebaseIndex__MCP__IndexReader_dependency_graph -->|method_call| CodebaseIndex__DependencyGraph
  CodebaseIndex__MCP__IndexReader_graph_analysis["CodebaseIndex::MCP::IndexReader#graph_analysis"]
  CodebaseIndex__MCP__IndexReader_find_unit["CodebaseIndex::MCP::IndexReader#find_unit"]
  CodebaseIndex__MCP__IndexReader_list_units["CodebaseIndex::MCP::IndexReader#list_units"]
  TYPE_TO_DIR["TYPE_TO_DIR"]
  CodebaseIndex__MCP__IndexReader_list_units -->|method_call| TYPE_TO_DIR
  CodebaseIndex__MCP__IndexReader_search["CodebaseIndex::MCP::IndexReader#search"]
  CodebaseIndex__MCP__IndexReader_search -->|method_call| Regexp
  CodebaseIndex__MCP__IndexReader_search -->|method_call| TYPE_TO_DIR
  DIR_TO_TYPE["DIR_TO_TYPE"]
  CodebaseIndex__MCP__IndexReader_search -->|method_call| DIR_TO_TYPE
  CodebaseIndex__MCP__IndexReader_traverse_dependencies["CodebaseIndex::MCP::IndexReader#traverse_dependencies"]
  CodebaseIndex__MCP__IndexReader_traverse_dependents["CodebaseIndex::MCP::IndexReader#traverse_dependents"]
  CodebaseIndex__MCP__IndexReader_framework_sources["CodebaseIndex::MCP::IndexReader#framework_sources"]
  CodebaseIndex__MCP__IndexReader_framework_sources -->|method_call| Regexp
  CodebaseIndex__MCP__IndexReader_recent_changes["CodebaseIndex::MCP::IndexReader#recent_changes"]
  CodebaseIndex__MCP__IndexReader_recent_changes -->|method_call| TYPE_TO_DIR
  CodebaseIndex__MCP__IndexReader_raw_graph_data["CodebaseIndex::MCP::IndexReader#raw_graph_data"]
  CodebaseIndex__MCP__IndexReader_identifier_map["CodebaseIndex::MCP::IndexReader#identifier_map"]
  CodebaseIndex__MCP__IndexReader_build_identifier_map["CodebaseIndex::MCP::IndexReader#build_identifier_map"]
  TYPE_DIRS["TYPE_DIRS"]
  CodebaseIndex__MCP__IndexReader_build_identifier_map -->|method_call| TYPE_DIRS
  CodebaseIndex__MCP__IndexReader_read_index["CodebaseIndex::MCP::IndexReader#read_index"]
  CodebaseIndex__MCP__IndexReader_read_index -->|method_call| JSON
  CodebaseIndex__MCP__IndexReader_load_unit["CodebaseIndex::MCP::IndexReader#load_unit"]
  CodebaseIndex__MCP__IndexReader_load_unit -->|method_call| JSON
  CodebaseIndex__MCP__IndexReader_parse_json["CodebaseIndex::MCP::IndexReader#parse_json"]
  CodebaseIndex__MCP__IndexReader_parse_json -->|method_call| JSON
  CodebaseIndex__MCP__IndexReader_traverse["CodebaseIndex::MCP::IndexReader#traverse"]
  CodebaseIndex__MCP__IndexReader_traverse -->|method_call| Set
  CodebaseIndex__MCP__Server["CodebaseIndex::MCP::Server"]
  CodebaseIndex__ModelNameCache["CodebaseIndex::ModelNameCache"]
  CodebaseIndex__Observability["CodebaseIndex::Observability"]
  CodebaseIndex__Observability__HealthCheck["CodebaseIndex::Observability::HealthCheck"]
  CodebaseIndex__Observability__HealthCheck_initialize["CodebaseIndex::Observability::HealthCheck#initialize"]
  CodebaseIndex__Observability__HealthCheck_run["CodebaseIndex::Observability::HealthCheck#run"]
  HealthStatus["HealthStatus"]
  CodebaseIndex__Observability__HealthCheck_run -->|method_call| HealthStatus
  CodebaseIndex__Observability__HealthCheck_probe_store["CodebaseIndex::Observability::HealthCheck#probe_store"]
  CodebaseIndex__Observability__HealthCheck_probe_provider["CodebaseIndex::Observability::HealthCheck#probe_provider"]
  CodebaseIndex__Observability__Instrumentation["CodebaseIndex::Observability::Instrumentation"]
  CodebaseIndex__Observability__Instrumentation_instrument["CodebaseIndex::Observability::Instrumentation#instrument"]
  ActiveSupport__Notifications["ActiveSupport::Notifications"]
  CodebaseIndex__Observability__Instrumentation_instrument -->|method_call| ActiveSupport__Notifications
  CodebaseIndex__Observability__StructuredLogger["CodebaseIndex::Observability::StructuredLogger"]
  CodebaseIndex__Observability__StructuredLogger_initialize["CodebaseIndex::Observability::StructuredLogger#initialize"]
  CodebaseIndex__Observability__StructuredLogger_info["CodebaseIndex::Observability::StructuredLogger#info"]
  CodebaseIndex__Observability__StructuredLogger_warn["CodebaseIndex::Observability::StructuredLogger#warn"]
  CodebaseIndex__Observability__StructuredLogger_error["CodebaseIndex::Observability::StructuredLogger#error"]
  CodebaseIndex__Observability__StructuredLogger_debug["CodebaseIndex::Observability::StructuredLogger#debug"]
  CodebaseIndex__Observability__StructuredLogger_write_entry["CodebaseIndex::Observability::StructuredLogger#write_entry"]
  CodebaseIndex__Operator["CodebaseIndex::Operator"]
  CodebaseIndex__Operator__ErrorEscalator["CodebaseIndex::Operator::ErrorEscalator"]
  CodebaseIndex__Operator__ErrorEscalator_classify["CodebaseIndex::Operator::ErrorEscalator#classify"]
  CodebaseIndex__Operator__ErrorEscalator_find_match["CodebaseIndex::Operator::ErrorEscalator#find_match"]
  CodebaseIndex__Operator__PipelineGuard["CodebaseIndex::Operator::PipelineGuard"]
  CodebaseIndex__Operator__PipelineGuard_initialize["CodebaseIndex::Operator::PipelineGuard#initialize"]
  CodebaseIndex__Operator__PipelineGuard_initialize -->|method_call| File
  CodebaseIndex__Operator__PipelineGuard_allow_["CodebaseIndex::Operator::PipelineGuard#allow?"]
  CodebaseIndex__Operator__PipelineGuard_allow_ -->|method_call| Time_now
  CodebaseIndex__Operator__PipelineGuard_allow_ -->|method_call| Time
  CodebaseIndex__Operator__PipelineGuard_record_["CodebaseIndex::Operator::PipelineGuard#record!"]
  CodebaseIndex__Operator__PipelineGuard_record_ -->|method_call| FileUtils
  CodebaseIndex__Operator__PipelineGuard_record_ -->|method_call| File
  CodebaseIndex__Operator__PipelineGuard_record_ -->|method_call| JSON
  CodebaseIndex__Operator__PipelineGuard_last_run["CodebaseIndex::Operator::PipelineGuard#last_run"]
  CodebaseIndex__Operator__PipelineGuard_last_run -->|method_call| Time
  CodebaseIndex__Operator__PipelineGuard_read_state["CodebaseIndex::Operator::PipelineGuard#read_state"]
  CodebaseIndex__Operator__PipelineGuard_read_state -->|method_call| File
  CodebaseIndex__Operator__PipelineGuard_read_state -->|method_call| JSON
  CodebaseIndex__Operator__PipelineGuard_write_state["CodebaseIndex::Operator::PipelineGuard#write_state"]
  CodebaseIndex__Operator__PipelineGuard_write_state -->|method_call| FileUtils
  CodebaseIndex__Operator__PipelineGuard_write_state -->|method_call| File
  CodebaseIndex__Operator__StatusReporter["CodebaseIndex::Operator::StatusReporter"]
  CodebaseIndex__Operator__StatusReporter_initialize["CodebaseIndex::Operator::StatusReporter#initialize"]
  CodebaseIndex__Operator__StatusReporter_report["CodebaseIndex::Operator::StatusReporter#report"]
  CodebaseIndex__Operator__StatusReporter_read_manifest["CodebaseIndex::Operator::StatusReporter#read_manifest"]
  CodebaseIndex__Operator__StatusReporter_read_manifest -->|method_call| File
  CodebaseIndex__Operator__StatusReporter_read_manifest -->|method_call| JSON
  CodebaseIndex__Operator__StatusReporter_not_extracted_report["CodebaseIndex::Operator::StatusReporter#not_extracted_report"]
  CodebaseIndex__Operator__StatusReporter_compute_staleness["CodebaseIndex::Operator::StatusReporter#compute_staleness"]
  CodebaseIndex__Operator__StatusReporter_compute_staleness -->|method_call| Time_now
  CodebaseIndex__Operator__StatusReporter_compute_staleness -->|method_call| Time
  CodebaseIndex__Railtie["CodebaseIndex::Railtie"]
  Rails__Railtie["Rails::Railtie"]
  CodebaseIndex__Railtie -->|inheritance| Rails__Railtie
  CodebaseIndex__Resilience["CodebaseIndex::Resilience"]
  CodebaseIndex__Resilience__CircuitOpenError["CodebaseIndex::Resilience::CircuitOpenError"]
  CodebaseIndex__Resilience__CircuitOpenError -->|inheritance| CodebaseIndex__Error
  CodebaseIndex__Resilience__CircuitBreaker["CodebaseIndex::Resilience::CircuitBreaker"]
  CodebaseIndex__Resilience__CircuitBreaker_initialize["CodebaseIndex::Resilience::CircuitBreaker#initialize"]
  CodebaseIndex__Resilience__CircuitBreaker_initialize -->|method_call| Mutex
  CodebaseIndex__Resilience__CircuitBreaker_call["CodebaseIndex::Resilience::CircuitBreaker#call"]
  Time_now__["Time.now.-"]
  CodebaseIndex__Resilience__CircuitBreaker_call -->|method_call| Time_now__
  CodebaseIndex__Resilience__CircuitBreaker_call -->|method_call| Time_now
  CodebaseIndex__Resilience__CircuitBreaker_call -->|method_call| Time
  CodebaseIndex__Resilience__CircuitBreaker_record_failure["CodebaseIndex::Resilience::CircuitBreaker#record_failure"]
  CodebaseIndex__Resilience__CircuitBreaker_record_failure -->|method_call| Time
  CodebaseIndex__Resilience__CircuitBreaker_reset_["CodebaseIndex::Resilience::CircuitBreaker#reset!"]
  CodebaseIndex__Resilience__IndexValidator["CodebaseIndex::Resilience::IndexValidator"]
  CodebaseIndex__Resilience__IndexValidator_initialize["CodebaseIndex::Resilience::IndexValidator#initialize"]
  CodebaseIndex__Resilience__IndexValidator_validate["CodebaseIndex::Resilience::IndexValidator#validate"]
  CodebaseIndex__Resilience__IndexValidator_validate -->|method_call| Dir
  ValidationReport["ValidationReport"]
  CodebaseIndex__Resilience__IndexValidator_validate -->|method_call| ValidationReport
  Dir_children["Dir.children"]
  CodebaseIndex__Resilience__IndexValidator_validate -->|method_call| Dir_children
  CodebaseIndex__Resilience__IndexValidator_validate -->|method_call| File
  CodebaseIndex__Resilience__IndexValidator_validate_type_directory["CodebaseIndex::Resilience::IndexValidator#validate_type_directory"]
  CodebaseIndex__Resilience__IndexValidator_validate_type_directory -->|method_call| File
  CodebaseIndex__Resilience__IndexValidator_validate_type_directory -->|method_call| JSON
  CodebaseIndex__Resilience__IndexValidator_validate_type_directory -->|method_call| Set
  CodebaseIndex__Resilience__IndexValidator_validate_index_entry["CodebaseIndex::Resilience::IndexValidator#validate_index_entry"]
  CodebaseIndex__Resilience__IndexValidator_find_unit_file["CodebaseIndex::Resilience::IndexValidator#find_unit_file"]
  CodebaseIndex__Resilience__IndexValidator_find_unit_file -->|method_call| File
  CodebaseIndex__Resilience__IndexValidator_validate_content_hash["CodebaseIndex::Resilience::IndexValidator#validate_content_hash"]
  CodebaseIndex__Resilience__IndexValidator_validate_content_hash -->|method_call| JSON
  CodebaseIndex__Resilience__IndexValidator_validate_content_hash -->|method_call| Digest__SHA256
  CodebaseIndex__Resilience__IndexValidator_check_stale_files["CodebaseIndex::Resilience::IndexValidator#check_stale_files"]
  CodebaseIndex__Resilience__IndexValidator_check_stale_files -->|method_call| Dir___
  CodebaseIndex__Resilience__IndexValidator_check_stale_files -->|method_call| File
  CodebaseIndex__Resilience__IndexValidator_safe_filename["CodebaseIndex::Resilience::IndexValidator#safe_filename"]
  CodebaseIndex__Resilience__RetryableProvider["CodebaseIndex::Resilience::RetryableProvider"]
  CodebaseIndex__Resilience__RetryableProvider -->|include| CodebaseIndex__Embedding__Provider__Interface
  CodebaseIndex__Resilience__RetryableProvider_initialize["CodebaseIndex::Resilience::RetryableProvider#initialize"]
  CodebaseIndex__Resilience__RetryableProvider_embed["CodebaseIndex::Resilience::RetryableProvider#embed"]
  CodebaseIndex__Resilience__RetryableProvider_embed_batch["CodebaseIndex::Resilience::RetryableProvider#embed_batch"]
  CodebaseIndex__Resilience__RetryableProvider_dimensions["CodebaseIndex::Resilience::RetryableProvider#dimensions"]
  CodebaseIndex__Resilience__RetryableProvider_model_name["CodebaseIndex::Resilience::RetryableProvider#model_name"]
  CodebaseIndex__Resilience__RetryableProvider_with_retries["CodebaseIndex::Resilience::RetryableProvider#with_retries"]
  CodebaseIndex__Resilience__RetryableProvider_call_provider["CodebaseIndex::Resilience::RetryableProvider#call_provider"]
  CodebaseIndex__Retrieval["CodebaseIndex::Retrieval"]
  CodebaseIndex__Retrieval__ContextAssembler["CodebaseIndex::Retrieval::ContextAssembler"]
  CodebaseIndex__Retrieval__ContextAssembler_initialize["CodebaseIndex::Retrieval::ContextAssembler#initialize"]
  CodebaseIndex__Retrieval__ContextAssembler_assemble["CodebaseIndex::Retrieval::ContextAssembler#assemble"]
  CodebaseIndex__Retrieval__ContextAssembler_add_structural_section["CodebaseIndex::Retrieval::ContextAssembler#add_structural_section"]
  CodebaseIndex__Retrieval__ContextAssembler_add_candidate_section["CodebaseIndex::Retrieval::ContextAssembler#add_candidate_section"]
  CodebaseIndex__Retrieval__ContextAssembler_compute_section_budgets["CodebaseIndex::Retrieval::ContextAssembler#compute_section_budgets"]
  CodebaseIndex__Retrieval__ContextAssembler_assemble_section["CodebaseIndex::Retrieval::ContextAssembler#assemble_section"]
  CodebaseIndex__Retrieval__ContextAssembler_append_candidate["CodebaseIndex::Retrieval::ContextAssembler#append_candidate"]
  CodebaseIndex__Retrieval__ContextAssembler_format_unit["CodebaseIndex::Retrieval::ContextAssembler#format_unit"]
  CodebaseIndex__Retrieval__ContextAssembler_build_source_attribution["CodebaseIndex::Retrieval::ContextAssembler#build_source_attribution"]
  CodebaseIndex__Retrieval__ContextAssembler_framework_candidate_["CodebaseIndex::Retrieval::ContextAssembler#framework_candidate?"]
  CodebaseIndex__Retrieval__ContextAssembler_truncate_to_budget["CodebaseIndex::Retrieval::ContextAssembler#truncate_to_budget"]
  CodebaseIndex__Retrieval__ContextAssembler_estimate_tokens["CodebaseIndex::Retrieval::ContextAssembler#estimate_tokens"]
  CodebaseIndex__Retrieval__ContextAssembler_build_result["CodebaseIndex::Retrieval::ContextAssembler#build_result"]
  AssembledContext["AssembledContext"]
  CodebaseIndex__Retrieval__ContextAssembler_build_result -->|method_call| AssembledContext
  CodebaseIndex__Retrieval__QueryClassifier["CodebaseIndex::Retrieval::QueryClassifier"]
  CodebaseIndex__Retrieval__QueryClassifier_classify["CodebaseIndex::Retrieval::QueryClassifier#classify"]
  Classification["Classification"]
  CodebaseIndex__Retrieval__QueryClassifier_classify -->|method_call| Classification
  CodebaseIndex__Retrieval__QueryClassifier_detect_intent["CodebaseIndex::Retrieval::QueryClassifier#detect_intent"]
  INTENT_PATTERNS["INTENT_PATTERNS"]
  CodebaseIndex__Retrieval__QueryClassifier_detect_intent -->|method_call| INTENT_PATTERNS
  CodebaseIndex__Retrieval__QueryClassifier_detect_scope["CodebaseIndex::Retrieval::QueryClassifier#detect_scope"]
  SCOPE_PATTERNS["SCOPE_PATTERNS"]
  CodebaseIndex__Retrieval__QueryClassifier_detect_scope -->|method_call| SCOPE_PATTERNS
  CodebaseIndex__Retrieval__QueryClassifier_detect_target_type["CodebaseIndex::Retrieval::QueryClassifier#detect_target_type"]
  TARGET_PATTERNS["TARGET_PATTERNS"]
  CodebaseIndex__Retrieval__QueryClassifier_detect_target_type -->|method_call| TARGET_PATTERNS
  CodebaseIndex__Retrieval__QueryClassifier_framework_query_["CodebaseIndex::Retrieval::QueryClassifier#framework_query?"]
  CodebaseIndex__Retrieval__QueryClassifier_extract_keywords["CodebaseIndex::Retrieval::QueryClassifier#extract_keywords"]
  STOP_WORDS["STOP_WORDS"]
  CodebaseIndex__Retrieval__QueryClassifier_extract_keywords -->|method_call| STOP_WORDS
  CodebaseIndex__Retrieval__Ranker["CodebaseIndex::Retrieval::Ranker"]
  CodebaseIndex__Retrieval__Ranker_initialize["CodebaseIndex::Retrieval::Ranker#initialize"]
  CodebaseIndex__Retrieval__Ranker_rank["CodebaseIndex::Retrieval::Ranker#rank"]
  CodebaseIndex__Retrieval__Ranker_multi_source_["CodebaseIndex::Retrieval::Ranker#multi_source?"]
  CodebaseIndex__Retrieval__Ranker_apply_rrf["CodebaseIndex::Retrieval::Ranker#apply_rrf"]
  CodebaseIndex__Retrieval__Ranker_compute_rrf_scores["CodebaseIndex::Retrieval::Ranker#compute_rrf_scores"]
  CodebaseIndex__Retrieval__Ranker_compute_rrf_scores -->|method_call| Hash
  CodebaseIndex__Retrieval__Ranker_rebuild_rrf_candidates["CodebaseIndex::Retrieval::Ranker#rebuild_rrf_candidates"]
  CodebaseIndex__Retrieval__Ranker_score_candidates["CodebaseIndex::Retrieval::Ranker#score_candidates"]
  CodebaseIndex__Retrieval__Ranker_sorted_by_weighted_score["CodebaseIndex::Retrieval::Ranker#sorted_by_weighted_score"]
  CodebaseIndex__Retrieval__Ranker_keyword_score["CodebaseIndex::Retrieval::Ranker#keyword_score"]
  CodebaseIndex__Retrieval__Ranker_recency_score["CodebaseIndex::Retrieval::Ranker#recency_score"]
  CodebaseIndex__Retrieval__Ranker_importance_score["CodebaseIndex::Retrieval::Ranker#importance_score"]
  CodebaseIndex__Retrieval__Ranker_type_match_score["CodebaseIndex::Retrieval::Ranker#type_match_score"]
  CodebaseIndex__Retrieval__Ranker_apply_diversity_penalty["CodebaseIndex::Retrieval::Ranker#apply_diversity_penalty"]
  CodebaseIndex__Retrieval__Ranker_apply_diversity_penalty -->|method_call| Hash
  CodebaseIndex__Retrieval__Ranker_diversity_penalty_for["CodebaseIndex::Retrieval::Ranker#diversity_penalty_for"]
  CodebaseIndex__Retrieval__Ranker_dig_metadata["CodebaseIndex::Retrieval::Ranker#dig_metadata"]
  CodebaseIndex__Retrieval__Ranker_build_candidate["CodebaseIndex::Retrieval::Ranker#build_candidate"]
  SearchExecutor__Candidate["SearchExecutor::Candidate"]
  CodebaseIndex__Retrieval__Ranker_build_candidate -->|method_call| SearchExecutor__Candidate
  CodebaseIndex__Retrieval__SearchExecutor["CodebaseIndex::Retrieval::SearchExecutor"]
  CodebaseIndex__Retrieval__SearchExecutor_initialize["CodebaseIndex::Retrieval::SearchExecutor#initialize"]
  CodebaseIndex__Retrieval__SearchExecutor_execute["CodebaseIndex::Retrieval::SearchExecutor#execute"]
  ExecutionResult["ExecutionResult"]
  CodebaseIndex__Retrieval__SearchExecutor_execute -->|method_call| ExecutionResult
  CodebaseIndex__Retrieval__SearchExecutor_select_strategy["CodebaseIndex::Retrieval::SearchExecutor#select_strategy"]
  STRATEGY_MAP["STRATEGY_MAP"]
  CodebaseIndex__Retrieval__SearchExecutor_select_strategy -->|method_call| STRATEGY_MAP
  CodebaseIndex__Retrieval__SearchExecutor_run_strategy["CodebaseIndex::Retrieval::SearchExecutor#run_strategy"]
  CodebaseIndex__Retrieval__SearchExecutor_execute_vector["CodebaseIndex::Retrieval::SearchExecutor#execute_vector"]
  Candidate["Candidate"]
  CodebaseIndex__Retrieval__SearchExecutor_execute_vector -->|method_call| Candidate
  CodebaseIndex__Retrieval__SearchExecutor_execute_keyword["CodebaseIndex::Retrieval::SearchExecutor#execute_keyword"]
  CodebaseIndex__Retrieval__SearchExecutor_merge_keyword_results["CodebaseIndex::Retrieval::SearchExecutor#merge_keyword_results"]
  CodebaseIndex__Retrieval__SearchExecutor_rank_keyword_results["CodebaseIndex::Retrieval::SearchExecutor#rank_keyword_results"]
  CodebaseIndex__Retrieval__SearchExecutor_rank_keyword_results -->|method_call| Candidate
  CodebaseIndex__Retrieval__SearchExecutor_execute_graph["CodebaseIndex::Retrieval::SearchExecutor#execute_graph"]
  CodebaseIndex__Retrieval__SearchExecutor_execute_hybrid["CodebaseIndex::Retrieval::SearchExecutor#execute_hybrid"]
  CodebaseIndex__Retrieval__SearchExecutor_execute_direct["CodebaseIndex::Retrieval::SearchExecutor#execute_direct"]
  CodebaseIndex__Retrieval__SearchExecutor_lookup_keyword_variants["CodebaseIndex::Retrieval::SearchExecutor#lookup_keyword_variants"]
  CodebaseIndex__Retrieval__SearchExecutor_build_vector_filters["CodebaseIndex::Retrieval::SearchExecutor#build_vector_filters"]
  CodebaseIndex__Retrieval__SearchExecutor_find_seed_identifiers["CodebaseIndex::Retrieval::SearchExecutor#find_seed_identifiers"]
  CodebaseIndex__Retrieval__SearchExecutor_deduplicate["CodebaseIndex::Retrieval::SearchExecutor#deduplicate"]
  CodebaseIndex__Retriever["CodebaseIndex::Retriever"]
  CodebaseIndex__Retriever_initialize["CodebaseIndex::Retriever#initialize"]
  Retrieval__QueryClassifier["Retrieval::QueryClassifier"]
  CodebaseIndex__Retriever_initialize -->|method_call| Retrieval__QueryClassifier
  Retrieval__SearchExecutor["Retrieval::SearchExecutor"]
  CodebaseIndex__Retriever_initialize -->|method_call| Retrieval__SearchExecutor
  Retrieval__Ranker["Retrieval::Ranker"]
  CodebaseIndex__Retriever_initialize -->|method_call| Retrieval__Ranker
  Retrieval__ContextAssembler["Retrieval::ContextAssembler"]
  CodebaseIndex__Retriever_initialize -->|method_call| Retrieval__ContextAssembler
  CodebaseIndex__Retriever_retrieve["CodebaseIndex::Retriever#retrieve"]
  CodebaseIndex__Retriever_retrieve -->|method_call| Process
  CodebaseIndex__Retriever_retrieve -->|method_call| Process_clock_gettime
  RetrievalTrace["RetrievalTrace"]
  CodebaseIndex__Retriever_retrieve -->|method_call| RetrievalTrace
  CodebaseIndex__Retriever_assemble_context["CodebaseIndex::Retriever#assemble_context"]
  CodebaseIndex__Retriever_build_result["CodebaseIndex::Retriever#build_result"]
  RetrievalResult["RetrievalResult"]
  CodebaseIndex__Retriever_build_result -->|method_call| RetrievalResult
  CodebaseIndex__Retriever_build_structural_context["CodebaseIndex::Retriever#build_structural_context"]
  STRUCTURAL_TYPES["STRUCTURAL_TYPES"]
  CodebaseIndex__Retriever_build_structural_context -->|method_call| STRUCTURAL_TYPES
  CodebaseIndex__Retriever_count_by_type["CodebaseIndex::Retriever#count_by_type"]
  CodebaseIndex__RubyAnalyzer["CodebaseIndex::RubyAnalyzer"]
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer["CodebaseIndex::RubyAnalyzer::ClassAnalyzer"]
  FqnBuilder["FqnBuilder"]
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer -->|include| FqnBuilder
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_initialize["CodebaseIndex::RubyAnalyzer::ClassAnalyzer#initialize"]
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_initialize -->|method_call| Ast__Parser
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_analyze["CodebaseIndex::RubyAnalyzer::ClassAnalyzer#analyze"]
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_extract_definitions["CodebaseIndex::RubyAnalyzer::ClassAnalyzer#extract_definitions"]
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_process_class["CodebaseIndex::RubyAnalyzer::ClassAnalyzer#process_class"]
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_process_module["CodebaseIndex::RubyAnalyzer::ClassAnalyzer#process_module"]
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_process_definition["CodebaseIndex::RubyAnalyzer::ClassAnalyzer#process_definition"]
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_process_definition -->|method_call| ExtractedUnit
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_build_namespace["CodebaseIndex::RubyAnalyzer::ClassAnalyzer#build_namespace"]
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_fqn_parts["CodebaseIndex::RubyAnalyzer::ClassAnalyzer#fqn_parts"]
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_extract_superclass["CodebaseIndex::RubyAnalyzer::ClassAnalyzer#extract_superclass"]
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_body_children["CodebaseIndex::RubyAnalyzer::ClassAnalyzer#body_children"]
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_extract_mixins["CodebaseIndex::RubyAnalyzer::ClassAnalyzer#extract_mixins"]
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_extract_constants["CodebaseIndex::RubyAnalyzer::ClassAnalyzer#extract_constants"]
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_count_methods["CodebaseIndex::RubyAnalyzer::ClassAnalyzer#count_methods"]
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_build_const_name["CodebaseIndex::RubyAnalyzer::ClassAnalyzer#build_const_name"]
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_extract_source["CodebaseIndex::RubyAnalyzer::ClassAnalyzer#extract_source"]
  CodebaseIndex__RubyAnalyzer__ClassAnalyzer_build_dependencies["CodebaseIndex::RubyAnalyzer::ClassAnalyzer#build_dependencies"]
  CodebaseIndex__RubyAnalyzer__DataFlowAnalyzer["CodebaseIndex::RubyAnalyzer::DataFlowAnalyzer"]
  CodebaseIndex__RubyAnalyzer__DataFlowAnalyzer_initialize["CodebaseIndex::RubyAnalyzer::DataFlowAnalyzer#initialize"]
  CodebaseIndex__RubyAnalyzer__DataFlowAnalyzer_initialize -->|method_call| Ast__Parser
  Ast__CallSiteExtractor["Ast::CallSiteExtractor"]
  CodebaseIndex__RubyAnalyzer__DataFlowAnalyzer_initialize -->|method_call| Ast__CallSiteExtractor
  CodebaseIndex__RubyAnalyzer__DataFlowAnalyzer_annotate["CodebaseIndex::RubyAnalyzer::DataFlowAnalyzer#annotate"]
  CodebaseIndex__RubyAnalyzer__DataFlowAnalyzer_detect_transformations["CodebaseIndex::RubyAnalyzer::DataFlowAnalyzer#detect_transformations"]
  CodebaseIndex__RubyAnalyzer__DataFlowAnalyzer_categorize["CodebaseIndex::RubyAnalyzer::DataFlowAnalyzer#categorize"]
  CONSTRUCTION_METHODS["CONSTRUCTION_METHODS"]
  CodebaseIndex__RubyAnalyzer__DataFlowAnalyzer_categorize -->|method_call| CONSTRUCTION_METHODS
  SERIALIZATION_METHODS["SERIALIZATION_METHODS"]
  CodebaseIndex__RubyAnalyzer__DataFlowAnalyzer_categorize -->|method_call| SERIALIZATION_METHODS
  DESERIALIZATION_METHODS["DESERIALIZATION_METHODS"]
  CodebaseIndex__RubyAnalyzer__DataFlowAnalyzer_categorize -->|method_call| DESERIALIZATION_METHODS
  CodebaseIndex__RubyAnalyzer__FqnBuilder["CodebaseIndex::RubyAnalyzer::FqnBuilder"]
  CodebaseIndex__RubyAnalyzer__FqnBuilder_build_fqn["CodebaseIndex::RubyAnalyzer::FqnBuilder#build_fqn"]
  CodebaseIndex__RubyAnalyzer__MermaidRenderer["CodebaseIndex::RubyAnalyzer::MermaidRenderer"]
  CodebaseIndex__RubyAnalyzer__MermaidRenderer_render_call_graph["CodebaseIndex::RubyAnalyzer::MermaidRenderer#render_call_graph"]
  CodebaseIndex__RubyAnalyzer__MermaidRenderer_render_dependency_map["CodebaseIndex::RubyAnalyzer::MermaidRenderer#render_dependency_map"]
  CodebaseIndex__RubyAnalyzer__MermaidRenderer_render_dataflow["CodebaseIndex::RubyAnalyzer::MermaidRenderer#render_dataflow"]
  CodebaseIndex__RubyAnalyzer__MermaidRenderer_render_architecture["CodebaseIndex::RubyAnalyzer::MermaidRenderer#render_architecture"]
  CodebaseIndex__RubyAnalyzer__MermaidRenderer_sanitize_id["CodebaseIndex::RubyAnalyzer::MermaidRenderer#sanitize_id"]
  CodebaseIndex__RubyAnalyzer__MermaidRenderer_escape_label["CodebaseIndex::RubyAnalyzer::MermaidRenderer#escape_label"]
  CodebaseIndex__RubyAnalyzer__MermaidRenderer_dataflow_shape["CodebaseIndex::RubyAnalyzer::MermaidRenderer#dataflow_shape"]
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer["CodebaseIndex::RubyAnalyzer::MethodAnalyzer"]
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer -->|include| FqnBuilder
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer__VisibilityTracker["CodebaseIndex::RubyAnalyzer::MethodAnalyzer::VisibilityTracker"]
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer_initialize["CodebaseIndex::RubyAnalyzer::MethodAnalyzer#initialize"]
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer_initialize -->|method_call| Ast__Parser
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer_initialize -->|method_call| Ast__CallSiteExtractor
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer_analyze["CodebaseIndex::RubyAnalyzer::MethodAnalyzer#analyze"]
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer_extract_methods_from_tree["CodebaseIndex::RubyAnalyzer::MethodAnalyzer#extract_methods_from_tree"]
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer_process_container_methods["CodebaseIndex::RubyAnalyzer::MethodAnalyzer#process_container_methods"]
  VisibilityTracker["VisibilityTracker"]
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer_process_container_methods -->|method_call| VisibilityTracker
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer_build_method_unit["CodebaseIndex::RubyAnalyzer::MethodAnalyzer#build_method_unit"]
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer_build_method_unit -->|method_call| ExtractedUnit
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer_extract_call_graph["CodebaseIndex::RubyAnalyzer::MethodAnalyzer#extract_call_graph"]
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer_build_dependencies["CodebaseIndex::RubyAnalyzer::MethodAnalyzer#build_dependencies"]
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer__VisibilityTracker_initialize["CodebaseIndex::RubyAnalyzer::MethodAnalyzer::VisibilityTracker#initialize"]
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer__VisibilityTracker_process_send["CodebaseIndex::RubyAnalyzer::MethodAnalyzer::VisibilityTracker#process_send"]
  VISIBILITY_METHODS["VISIBILITY_METHODS"]
  CodebaseIndex__RubyAnalyzer__MethodAnalyzer__VisibilityTracker_process_send -->|method_call| VISIBILITY_METHODS
  CodebaseIndex__RubyAnalyzer__TraceEnricher["CodebaseIndex::RubyAnalyzer::TraceEnricher"]
  CodebaseIndex__RubyAnalyzer__TraceEnricher_record["CodebaseIndex::RubyAnalyzer::TraceEnricher.record"]
  TracePoint["TracePoint"]
  CodebaseIndex__RubyAnalyzer__TraceEnricher_record -->|method_call| TracePoint
  CodebaseIndex__RubyAnalyzer__TraceEnricher_merge["CodebaseIndex::RubyAnalyzer::TraceEnricher.merge"]
  CodebaseIndex__SessionTracer["CodebaseIndex::SessionTracer"]
  CodebaseIndex__SessionTracer__FileStore["CodebaseIndex::SessionTracer::FileStore"]
  Store["Store"]
  CodebaseIndex__SessionTracer__FileStore -->|inheritance| Store
  CodebaseIndex__SessionTracer__FileStore_initialize["CodebaseIndex::SessionTracer::FileStore#initialize"]
  CodebaseIndex__SessionTracer__FileStore_initialize -->|method_call| FileUtils
  CodebaseIndex__SessionTracer__FileStore_record["CodebaseIndex::SessionTracer::FileStore#record"]
  CodebaseIndex__SessionTracer__FileStore_record -->|method_call| File
  CodebaseIndex__SessionTracer__FileStore_read["CodebaseIndex::SessionTracer::FileStore#read"]
  CodebaseIndex__SessionTracer__FileStore_read -->|method_call| File
  CodebaseIndex__SessionTracer__FileStore_read -->|method_call| File_readlines
  CodebaseIndex__SessionTracer__FileStore_read -->|method_call| JSON
  CodebaseIndex__SessionTracer__FileStore_sessions["CodebaseIndex::SessionTracer::FileStore#sessions"]
  CodebaseIndex__SessionTracer__FileStore_sessions -->|method_call| File
  CodebaseIndex__SessionTracer__FileStore_sessions -->|method_call| Dir_glob
  File_mtime_to_f["File.mtime.to_f"]
  CodebaseIndex__SessionTracer__FileStore_sessions -->|method_call| File_mtime_to_f
  File_mtime["File.mtime"]
  CodebaseIndex__SessionTracer__FileStore_sessions -->|method_call| File_mtime
  CodebaseIndex__SessionTracer__FileStore_clear["CodebaseIndex::SessionTracer::FileStore#clear"]
  CodebaseIndex__SessionTracer__FileStore_clear -->|method_call| FileUtils
  CodebaseIndex__SessionTracer__FileStore_clear_all["CodebaseIndex::SessionTracer::FileStore#clear_all"]
  CodebaseIndex__SessionTracer__FileStore_clear_all -->|method_call| File
  CodebaseIndex__SessionTracer__FileStore_clear_all -->|method_call| Dir_glob
  CodebaseIndex__SessionTracer__FileStore_session_path["CodebaseIndex::SessionTracer::FileStore#session_path"]
  CodebaseIndex__SessionTracer__FileStore_session_path -->|method_call| File
  CodebaseIndex__SessionTracer__Middleware["CodebaseIndex::SessionTracer::Middleware"]
  CodebaseIndex__SessionTracer__Middleware_initialize["CodebaseIndex::SessionTracer::Middleware#initialize"]
  CodebaseIndex__SessionTracer__Middleware_call["CodebaseIndex::SessionTracer::Middleware#call"]
  CodebaseIndex__SessionTracer__Middleware_call -->|method_call| Process
  CodebaseIndex__SessionTracer__Middleware_call -->|method_call| Process_clock_gettime
  CodebaseIndex__SessionTracer__Middleware_record_request["CodebaseIndex::SessionTracer::Middleware#record_request"]
  CodebaseIndex__SessionTracer__Middleware_extract_session_id["CodebaseIndex::SessionTracer::Middleware#extract_session_id"]
  CodebaseIndex__SessionTracer__Middleware_excluded_["CodebaseIndex::SessionTracer::Middleware#excluded?"]
  CodebaseIndex__SessionTracer__Middleware_classify_controller["CodebaseIndex::SessionTracer::Middleware#classify_controller"]
  CodebaseIndex__SessionTracer__Middleware_extract_format["CodebaseIndex::SessionTracer::Middleware#extract_format"]
  CodebaseIndex__SessionTracer__RedisStore["CodebaseIndex::SessionTracer::RedisStore"]
  CodebaseIndex__SessionTracer__RedisStore -->|inheritance| Store
  CodebaseIndex__SessionTracer__RedisStore_initialize["CodebaseIndex::SessionTracer::RedisStore#initialize"]
  CodebaseIndex__SessionTracer__RedisStore_record["CodebaseIndex::SessionTracer::RedisStore#record"]
  CodebaseIndex__SessionTracer__RedisStore_read["CodebaseIndex::SessionTracer::RedisStore#read"]
  CodebaseIndex__SessionTracer__RedisStore_read -->|method_call| JSON
  CodebaseIndex__SessionTracer__RedisStore_sessions["CodebaseIndex::SessionTracer::RedisStore#sessions"]
  CodebaseIndex__SessionTracer__RedisStore_clear["CodebaseIndex::SessionTracer::RedisStore#clear"]
  CodebaseIndex__SessionTracer__RedisStore_clear_all["CodebaseIndex::SessionTracer::RedisStore#clear_all"]
  CodebaseIndex__SessionTracer__RedisStore_session_key["CodebaseIndex::SessionTracer::RedisStore#session_key"]
  CodebaseIndex__SessionTracer__SessionFlowAssembler["CodebaseIndex::SessionTracer::SessionFlowAssembler"]
  CodebaseIndex__SessionTracer__SessionFlowAssembler_initialize["CodebaseIndex::SessionTracer::SessionFlowAssembler#initialize"]
  CodebaseIndex__SessionTracer__SessionFlowAssembler_assemble["CodebaseIndex::SessionTracer::SessionFlowAssembler#assemble"]
  CodebaseIndex__SessionTracer__SessionFlowAssembler_assemble -->|method_call| Set
  SessionFlowDocument["SessionFlowDocument"]
  CodebaseIndex__SessionTracer__SessionFlowAssembler_assemble -->|method_call| SessionFlowDocument
  CodebaseIndex__SessionTracer__SessionFlowAssembler_build_step["CodebaseIndex::SessionTracer::SessionFlowAssembler#build_step"]
  CodebaseIndex__SessionTracer__SessionFlowAssembler_resolve_dependencies["CodebaseIndex::SessionTracer::SessionFlowAssembler#resolve_dependencies"]
  ASYNC_TYPES["ASYNC_TYPES"]
  CodebaseIndex__SessionTracer__SessionFlowAssembler_resolve_dependencies -->|method_call| ASYNC_TYPES
  CodebaseIndex__SessionTracer__SessionFlowAssembler_expand_transitive["CodebaseIndex::SessionTracer::SessionFlowAssembler#expand_transitive"]
  CodebaseIndex__SessionTracer__SessionFlowAssembler_unit_summary["CodebaseIndex::SessionTracer::SessionFlowAssembler#unit_summary"]
  CodebaseIndex__SessionTracer__SessionFlowAssembler_apply_budget["CodebaseIndex::SessionTracer::SessionFlowAssembler#apply_budget"]
  CodebaseIndex__SessionTracer__SessionFlowAssembler_estimate_tokens["CodebaseIndex::SessionTracer::SessionFlowAssembler#estimate_tokens"]
  CodebaseIndex__SessionTracer__SessionFlowAssembler_estimate_token_count["CodebaseIndex::SessionTracer::SessionFlowAssembler#estimate_token_count"]
  CodebaseIndex__SessionTracer__SessionFlowAssembler_empty_document["CodebaseIndex::SessionTracer::SessionFlowAssembler#empty_document"]
  CodebaseIndex__SessionTracer__SessionFlowAssembler_empty_document -->|method_call| SessionFlowDocument
  CodebaseIndex__SessionTracer__SessionFlowDocument["CodebaseIndex::SessionTracer::SessionFlowDocument"]
  CodebaseIndex__SessionTracer__SessionFlowDocument_initialize["CodebaseIndex::SessionTracer::SessionFlowDocument#initialize"]
  Time_now_utc["Time.now.utc"]
  CodebaseIndex__SessionTracer__SessionFlowDocument_initialize -->|method_call| Time_now_utc
  CodebaseIndex__SessionTracer__SessionFlowDocument_initialize -->|method_call| Time_now
  CodebaseIndex__SessionTracer__SessionFlowDocument_initialize -->|method_call| Time
  CodebaseIndex__SessionTracer__SessionFlowDocument_to_h["CodebaseIndex::SessionTracer::SessionFlowDocument#to_h"]
  CodebaseIndex__SessionTracer__SessionFlowDocument_from_h["CodebaseIndex::SessionTracer::SessionFlowDocument.from_h"]
  CodebaseIndex__SessionTracer__SessionFlowDocument_to_markdown["CodebaseIndex::SessionTracer::SessionFlowDocument#to_markdown"]
  CodebaseIndex__SessionTracer__SessionFlowDocument_to_context["CodebaseIndex::SessionTracer::SessionFlowDocument#to_context"]
  CodebaseIndex__SessionTracer__SessionFlowDocument_deep_symbolize_keys["CodebaseIndex::SessionTracer::SessionFlowDocument.deep_symbolize_keys"]
  CodebaseIndex__SessionTracer__SolidCacheStore["CodebaseIndex::SessionTracer::SolidCacheStore"]
  CodebaseIndex__SessionTracer__SolidCacheStore -->|inheritance| Store
  CodebaseIndex__SessionTracer__SolidCacheStore_initialize["CodebaseIndex::SessionTracer::SolidCacheStore#initialize"]
  CodebaseIndex__SessionTracer__SolidCacheStore_record["CodebaseIndex::SessionTracer::SolidCacheStore#record"]
  CodebaseIndex__SessionTracer__SolidCacheStore_record -->|method_call| JSON
  CodebaseIndex__SessionTracer__SolidCacheStore_read["CodebaseIndex::SessionTracer::SolidCacheStore#read"]
  CodebaseIndex__SessionTracer__SolidCacheStore_read -->|method_call| JSON
  CodebaseIndex__SessionTracer__SolidCacheStore_sessions["CodebaseIndex::SessionTracer::SolidCacheStore#sessions"]
  CodebaseIndex__SessionTracer__SolidCacheStore_clear["CodebaseIndex::SessionTracer::SolidCacheStore#clear"]
  CodebaseIndex__SessionTracer__SolidCacheStore_clear_all["CodebaseIndex::SessionTracer::SolidCacheStore#clear_all"]
  CodebaseIndex__SessionTracer__SolidCacheStore_session_key["CodebaseIndex::SessionTracer::SolidCacheStore#session_key"]
  CodebaseIndex__SessionTracer__SolidCacheStore_read_index["CodebaseIndex::SessionTracer::SolidCacheStore#read_index"]
  CodebaseIndex__SessionTracer__SolidCacheStore_read_index -->|method_call| JSON
  CodebaseIndex__SessionTracer__SolidCacheStore_write_index["CodebaseIndex::SessionTracer::SolidCacheStore#write_index"]
  CodebaseIndex__SessionTracer__SolidCacheStore_update_index["CodebaseIndex::SessionTracer::SolidCacheStore#update_index"]
  CodebaseIndex__SessionTracer__Store["CodebaseIndex::SessionTracer::Store"]
  CodebaseIndex__SessionTracer__Store_record["CodebaseIndex::SessionTracer::Store#record"]
  CodebaseIndex__SessionTracer__Store_read["CodebaseIndex::SessionTracer::Store#read"]
  CodebaseIndex__SessionTracer__Store_sessions["CodebaseIndex::SessionTracer::Store#sessions"]
  CodebaseIndex__SessionTracer__Store_clear["CodebaseIndex::SessionTracer::Store#clear"]
  CodebaseIndex__SessionTracer__Store_clear_all["CodebaseIndex::SessionTracer::Store#clear_all"]
  CodebaseIndex__SessionTracer__Store_sanitize_session_id["CodebaseIndex::SessionTracer::Store#sanitize_session_id"]
  CodebaseIndex__Storage["CodebaseIndex::Storage"]
  CodebaseIndex__Storage__GraphStore["CodebaseIndex::Storage::GraphStore"]
  CodebaseIndex__Storage__GraphStore__Interface["CodebaseIndex::Storage::GraphStore::Interface"]
  CodebaseIndex__Storage__GraphStore__Memory["CodebaseIndex::Storage::GraphStore::Memory"]
  CodebaseIndex__Storage__GraphStore__Memory -->|include| Interface
  CodebaseIndex__Storage__GraphStore__Interface_dependencies_of["CodebaseIndex::Storage::GraphStore::Interface#dependencies_of"]
  CodebaseIndex__Storage__GraphStore__Interface_dependents_of["CodebaseIndex::Storage::GraphStore::Interface#dependents_of"]
  CodebaseIndex__Storage__GraphStore__Interface_affected_by["CodebaseIndex::Storage::GraphStore::Interface#affected_by"]
  CodebaseIndex__Storage__GraphStore__Interface_by_type["CodebaseIndex::Storage::GraphStore::Interface#by_type"]
  CodebaseIndex__Storage__GraphStore__Interface_pagerank["CodebaseIndex::Storage::GraphStore::Interface#pagerank"]
  CodebaseIndex__Storage__GraphStore__Memory_initialize["CodebaseIndex::Storage::GraphStore::Memory#initialize"]
  CodebaseIndex__Storage__GraphStore__Memory_initialize -->|method_call| DependencyGraph
  CodebaseIndex__Storage__GraphStore__Memory_register["CodebaseIndex::Storage::GraphStore::Memory#register"]
  CodebaseIndex__Storage__GraphStore__Memory_dependencies_of["CodebaseIndex::Storage::GraphStore::Memory#dependencies_of"]
  CodebaseIndex__Storage__GraphStore__Memory_dependents_of["CodebaseIndex::Storage::GraphStore::Memory#dependents_of"]
  CodebaseIndex__Storage__GraphStore__Memory_affected_by["CodebaseIndex::Storage::GraphStore::Memory#affected_by"]
  CodebaseIndex__Storage__GraphStore__Memory_by_type["CodebaseIndex::Storage::GraphStore::Memory#by_type"]
  CodebaseIndex__Storage__GraphStore__Memory_pagerank["CodebaseIndex::Storage::GraphStore::Memory#pagerank"]
  CodebaseIndex__Storage__MetadataStore["CodebaseIndex::Storage::MetadataStore"]
  CodebaseIndex__Storage__MetadataStore__Interface["CodebaseIndex::Storage::MetadataStore::Interface"]
  CodebaseIndex__Storage__MetadataStore__SQLite["CodebaseIndex::Storage::MetadataStore::SQLite"]
  CodebaseIndex__Storage__MetadataStore__SQLite -->|include| Interface
  CodebaseIndex__Storage__MetadataStore__Interface_store["CodebaseIndex::Storage::MetadataStore::Interface#store"]
  CodebaseIndex__Storage__MetadataStore__Interface_find["CodebaseIndex::Storage::MetadataStore::Interface#find"]
  CodebaseIndex__Storage__MetadataStore__Interface_find_by_type["CodebaseIndex::Storage::MetadataStore::Interface#find_by_type"]
  CodebaseIndex__Storage__MetadataStore__Interface_search["CodebaseIndex::Storage::MetadataStore::Interface#search"]
  CodebaseIndex__Storage__MetadataStore__Interface_delete["CodebaseIndex::Storage::MetadataStore::Interface#delete"]
  CodebaseIndex__Storage__MetadataStore__Interface_count["CodebaseIndex::Storage::MetadataStore::Interface#count"]
  CodebaseIndex__Storage__MetadataStore__SQLite_initialize["CodebaseIndex::Storage::MetadataStore::SQLite#initialize"]
  SQLite3__Database["SQLite3::Database"]
  CodebaseIndex__Storage__MetadataStore__SQLite_initialize -->|method_call| SQLite3__Database
  CodebaseIndex__Storage__MetadataStore__SQLite_store["CodebaseIndex::Storage::MetadataStore::SQLite#store"]
  CodebaseIndex__Storage__MetadataStore__SQLite_store -->|method_call| JSON
  CodebaseIndex__Storage__MetadataStore__SQLite_find["CodebaseIndex::Storage::MetadataStore::SQLite#find"]
  CodebaseIndex__Storage__MetadataStore__SQLite_find -->|method_call| JSON
  CodebaseIndex__Storage__MetadataStore__SQLite_find_by_type["CodebaseIndex::Storage::MetadataStore::SQLite#find_by_type"]
  CodebaseIndex__Storage__MetadataStore__SQLite_find_by_type -->|method_call| JSON
  CodebaseIndex__Storage__MetadataStore__SQLite_search["CodebaseIndex::Storage::MetadataStore::SQLite#search"]
  CodebaseIndex__Storage__MetadataStore__SQLite_search -->|method_call| JSON
  CodebaseIndex__Storage__MetadataStore__SQLite_delete["CodebaseIndex::Storage::MetadataStore::SQLite#delete"]
  CodebaseIndex__Storage__MetadataStore__SQLite_count["CodebaseIndex::Storage::MetadataStore::SQLite#count"]
  CodebaseIndex__Storage__MetadataStore__SQLite_create_table["CodebaseIndex::Storage::MetadataStore::SQLite#create_table"]
  CodebaseIndex__Storage__VectorStore["CodebaseIndex::Storage::VectorStore"]
  CodebaseIndex__Storage__VectorStore__Pgvector["CodebaseIndex::Storage::VectorStore::Pgvector"]
  CodebaseIndex__Storage__VectorStore__Pgvector -->|include| Interface
  CodebaseIndex__Storage__VectorStore__Pgvector_initialize["CodebaseIndex::Storage::VectorStore::Pgvector#initialize"]
  CodebaseIndex__Storage__VectorStore__Pgvector_ensure_schema_["CodebaseIndex::Storage::VectorStore::Pgvector#ensure_schema!"]
  CodebaseIndex__Storage__VectorStore__Pgvector_store["CodebaseIndex::Storage::VectorStore::Pgvector#store"]
  CodebaseIndex__Storage__VectorStore__Pgvector_search["CodebaseIndex::Storage::VectorStore::Pgvector#search"]
  CodebaseIndex__Storage__VectorStore__Pgvector_delete["CodebaseIndex::Storage::VectorStore::Pgvector#delete"]
  CodebaseIndex__Storage__VectorStore__Pgvector_delete_by_filter["CodebaseIndex::Storage::VectorStore::Pgvector#delete_by_filter"]
  CodebaseIndex__Storage__VectorStore__Pgvector_count["CodebaseIndex::Storage::VectorStore::Pgvector#count"]
  CodebaseIndex__Storage__VectorStore__Pgvector_row_to_result["CodebaseIndex::Storage::VectorStore::Pgvector#row_to_result"]
  CodebaseIndex__Storage__VectorStore__Pgvector_row_to_result -->|method_call| JSON
  SearchResult["SearchResult"]
  CodebaseIndex__Storage__VectorStore__Pgvector_row_to_result -->|method_call| SearchResult
  CodebaseIndex__Storage__VectorStore__Pgvector_build_where["CodebaseIndex::Storage::VectorStore::Pgvector#build_where"]
  CodebaseIndex__Storage__VectorStore__Pgvector_validate_vector_["CodebaseIndex::Storage::VectorStore::Pgvector#validate_vector!"]
  CodebaseIndex__Storage__VectorStore__Qdrant["CodebaseIndex::Storage::VectorStore::Qdrant"]
  CodebaseIndex__Storage__VectorStore__Qdrant -->|include| Interface
  CodebaseIndex__Storage__VectorStore__Qdrant_initialize["CodebaseIndex::Storage::VectorStore::Qdrant#initialize"]
  CodebaseIndex__Storage__VectorStore__Qdrant_ensure_collection_["CodebaseIndex::Storage::VectorStore::Qdrant#ensure_collection!"]
  CodebaseIndex__Storage__VectorStore__Qdrant_store["CodebaseIndex::Storage::VectorStore::Qdrant#store"]
  CodebaseIndex__Storage__VectorStore__Qdrant_search["CodebaseIndex::Storage::VectorStore::Qdrant#search"]
  CodebaseIndex__Storage__VectorStore__Qdrant_search -->|method_call| SearchResult
  CodebaseIndex__Storage__VectorStore__Qdrant_delete["CodebaseIndex::Storage::VectorStore::Qdrant#delete"]
  CodebaseIndex__Storage__VectorStore__Qdrant_delete_by_filter["CodebaseIndex::Storage::VectorStore::Qdrant#delete_by_filter"]
  CodebaseIndex__Storage__VectorStore__Qdrant_count["CodebaseIndex::Storage::VectorStore::Qdrant#count"]
  CodebaseIndex__Storage__VectorStore__Qdrant_build_filter["CodebaseIndex::Storage::VectorStore::Qdrant#build_filter"]
  CodebaseIndex__Storage__VectorStore__Qdrant_request["CodebaseIndex::Storage::VectorStore::Qdrant#request"]
  CodebaseIndex__Storage__VectorStore__Qdrant_request -->|method_call| JSON
  CodebaseIndex__Storage__VectorStore__Qdrant_build_http["CodebaseIndex::Storage::VectorStore::Qdrant#build_http"]
  CodebaseIndex__Storage__VectorStore__Qdrant_build_http -->|method_call| Net__HTTP
  CodebaseIndex__Storage__VectorStore__Qdrant_build_request["CodebaseIndex::Storage::VectorStore::Qdrant#build_request"]
  CodebaseIndex__Storage__VectorStore__Interface["CodebaseIndex::Storage::VectorStore::Interface"]
  CodebaseIndex__Storage__VectorStore__InMemory["CodebaseIndex::Storage::VectorStore::InMemory"]
  CodebaseIndex__Storage__VectorStore__InMemory -->|include| Interface
  CodebaseIndex__Storage__VectorStore__Interface_store["CodebaseIndex::Storage::VectorStore::Interface#store"]
  CodebaseIndex__Storage__VectorStore__Interface_search["CodebaseIndex::Storage::VectorStore::Interface#search"]
  CodebaseIndex__Storage__VectorStore__Interface_delete["CodebaseIndex::Storage::VectorStore::Interface#delete"]
  CodebaseIndex__Storage__VectorStore__Interface_delete_by_filter["CodebaseIndex::Storage::VectorStore::Interface#delete_by_filter"]
  CodebaseIndex__Storage__VectorStore__Interface_count["CodebaseIndex::Storage::VectorStore::Interface#count"]
  CodebaseIndex__Storage__VectorStore__InMemory_initialize["CodebaseIndex::Storage::VectorStore::InMemory#initialize"]
  CodebaseIndex__Storage__VectorStore__InMemory_store["CodebaseIndex::Storage::VectorStore::InMemory#store"]
  CodebaseIndex__Storage__VectorStore__InMemory_search["CodebaseIndex::Storage::VectorStore::InMemory#search"]
  CodebaseIndex__Storage__VectorStore__InMemory_search -->|method_call| SearchResult
  CodebaseIndex__Storage__VectorStore__InMemory_delete["CodebaseIndex::Storage::VectorStore::InMemory#delete"]
  CodebaseIndex__Storage__VectorStore__InMemory_delete_by_filter["CodebaseIndex::Storage::VectorStore::InMemory#delete_by_filter"]
  CodebaseIndex__Storage__VectorStore__InMemory_count["CodebaseIndex::Storage::VectorStore::InMemory#count"]
  CodebaseIndex__Storage__VectorStore__InMemory_filter_entries["CodebaseIndex::Storage::VectorStore::InMemory#filter_entries"]
  CodebaseIndex__Storage__VectorStore__InMemory_cosine_similarity["CodebaseIndex::Storage::VectorStore::InMemory#cosine_similarity"]
  Math["Math"]
  CodebaseIndex__Storage__VectorStore__InMemory_cosine_similarity -->|method_call| Math
  CodebaseIndex__Temporal["CodebaseIndex::Temporal"]
  CodebaseIndex__Temporal__SnapshotStore["CodebaseIndex::Temporal::SnapshotStore"]
  CodebaseIndex__Temporal__SnapshotStore_initialize["CodebaseIndex::Temporal::SnapshotStore#initialize"]
  CodebaseIndex__Temporal__SnapshotStore_capture["CodebaseIndex::Temporal::SnapshotStore#capture"]
  CodebaseIndex__Temporal__SnapshotStore_list["CodebaseIndex::Temporal::SnapshotStore#list"]
  CodebaseIndex__Temporal__SnapshotStore_find["CodebaseIndex::Temporal::SnapshotStore#find"]
  CodebaseIndex__Temporal__SnapshotStore_diff["CodebaseIndex::Temporal::SnapshotStore#diff"]
  CodebaseIndex__Temporal__SnapshotStore_unit_history["CodebaseIndex::Temporal::SnapshotStore#unit_history"]
  CodebaseIndex__Temporal__SnapshotStore_history_entry_from_row["CodebaseIndex::Temporal::SnapshotStore#history_entry_from_row"]
  CodebaseIndex__Temporal__SnapshotStore_mark_changed_entries["CodebaseIndex::Temporal::SnapshotStore#mark_changed_entries"]
  CodebaseIndex__Temporal__SnapshotStore_mget["CodebaseIndex::Temporal::SnapshotStore#mget"]
  CodebaseIndex__Temporal__SnapshotStore_upsert_snapshot["CodebaseIndex::Temporal::SnapshotStore#upsert_snapshot"]
  CodebaseIndex__Temporal__SnapshotStore_upsert_snapshot -->|method_call| Time_now
  CodebaseIndex__Temporal__SnapshotStore_upsert_snapshot -->|method_call| Time
  CodebaseIndex__Temporal__SnapshotStore_upsert_snapshot -->|method_call| JSON
  CodebaseIndex__Temporal__SnapshotStore_update_diff_stats["CodebaseIndex::Temporal::SnapshotStore#update_diff_stats"]
  CodebaseIndex__Temporal__SnapshotStore_find_latest["CodebaseIndex::Temporal::SnapshotStore#find_latest"]
  CodebaseIndex__Temporal__SnapshotStore_fetch_snapshot_id["CodebaseIndex::Temporal::SnapshotStore#fetch_snapshot_id"]
  CodebaseIndex__Temporal__SnapshotStore_insert_unit_hashes["CodebaseIndex::Temporal::SnapshotStore#insert_unit_hashes"]
  CodebaseIndex__Temporal__SnapshotStore_load_snapshot_units["CodebaseIndex::Temporal::SnapshotStore#load_snapshot_units"]
  CodebaseIndex__Temporal__SnapshotStore_compute_diff["CodebaseIndex::Temporal::SnapshotStore#compute_diff"]
  CodebaseIndex__Temporal__SnapshotStore_compute_diff_stats["CodebaseIndex::Temporal::SnapshotStore#compute_diff_stats"]
  CodebaseIndex__Temporal__SnapshotStore_row_to_hash["CodebaseIndex::Temporal::SnapshotStore#row_to_hash"]
```
