# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/sql_validator'

RSpec.describe Woods::Console::SqlValidator, 'keyword function policy' do
  %i[postgres mysql sqlite].each do |dialect|
    context "with #{dialect} grammar" do
      subject(:validator) { described_class.new(dialect: dialect) }

      callable_keywords = %w[END WITH ANY SOME BY ASC DESC OFFSET OVER PARTITION FILTER WITHIN EXPLAIN]
      callable_keywords -= %w[OFFSET ANY SOME] if dialect == :postgres # Reserved; cannot name a bare function.
      callable_keywords.each do |name|
        it "does not exempt a function named #{name}" do
          expect { validator.validate!("SELECT #{name}()") }
            .to raise_error(Woods::Console::SqlValidationError, /allowlist/)
        end
      end

      [
        'SELECT row_number() OVER (ORDER BY (id)) FROM users',
        'SELECT id FROM users WHERE id IN (SELECT id FROM users)',
        'SELECT id FROM users WHERE (id = 1) LIMIT (10) OFFSET (0)',
        'SELECT id FROM users GROUP BY (id) HAVING (count(*) > 1)'
      ].each do |sql|
        it "retains ordinary parenthesized grammar: #{sql}" do
          expect { validator.validate!(sql) }.not_to raise_error
        end
      end
    end
  end

  %i[postgres mysql].each do |dialect|
    %w[ANY SOME ALL].each do |quantifier|
      it "retains #{dialect} #{quantifier} comparison subqueries" do
        expect { described_class.new(dialect: dialect).validate!("SELECT 1 = #{quantifier} (SELECT 1)") }
          .not_to raise_error
      end
    end
  end

  [
    'EXPLAIN (FORMAT JSON) SELECT 1',
    'SELECT count(*) FILTER (WHERE id > 1) OVER () FROM users',
    'SELECT id FROM users LIMIT ALL OFFSET (0)',
    'SELECT id FROM users OFFSET (0)',
    "SELECT 'a' LIKE ANY (ARRAY['a'])",
    "SELECT 'a' ILIKE SOME (ARRAY['A'])"
  ].each do |sql|
    it "retains PostgreSQL grammar: #{sql}" do
      expect { described_class.new(dialect: :postgres).validate!(sql) }.not_to raise_error
    end
  end
end
