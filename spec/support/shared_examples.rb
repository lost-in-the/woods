# frozen_string_literal: true

RSpec.shared_examples 'handles missing directories' do
  it 'handles missing directories gracefully' do
    extractor = described_class.new
    expect(extractor.extract_all).to eq([])
  end
end

RSpec.shared_examples 'all dependencies have :via key' do |extract_method, file_path, file_content|
  it 'includes :via key on all dependencies' do
    path = create_file(file_path, file_content)
    unit = described_class.new.public_send(extract_method, path)
    unit.dependencies.each do |dep|
      expect(dep).to have_key(:via), "Dependency #{dep.inspect} missing :via key"
    end
  end
end
