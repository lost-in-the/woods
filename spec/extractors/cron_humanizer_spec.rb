# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/cron_humanizer'

RSpec.describe Woods::Extractors::CronHumanizer do
  def humanize(expression)
    described_class.humanize(expression)
  end

  describe 'shapes that already had names' do
    {
      '* * * * *' => 'every minute',
      '0 * * * *' => 'every hour',
      '0 0 * * *' => 'daily at midnight',
      '*/5 * * * *' => 'every 5 minutes'
    }.each do |cron, text|
      it "keeps #{cron.inspect} as #{text.inspect}" do
        expect(humanize(cron)).to eq(text)
      end
    end
  end

  describe 'named shapes that left out the time or used ordinals' do
    {
      '0 0 * * 0' => 'weekly on Sunday at 00:00',
      '0 0 * * 1' => 'weekly on Monday at 00:00',
      '0 0 1 * *' => 'monthly on day 1 at 00:00',
      '0 0 1 1 *' => 'yearly on January 1 at 00:00'
    }.each do |cron, text|
      it "describes #{cron.inspect} as #{text.inspect}, with its time and a plain day number" do
        expect(humanize(cron)).to eq(text)
      end
    end
  end

  describe 'minute and hour shapes' do
    {
      '35 * * * *' => 'hourly at :35',
      '0,30 * * * *' => 'hourly at :00 and :30',
      '5,25,45 * * * *' => 'hourly at :05, :25 and :45',
      '*/1 * * * *' => 'every minute',
      '15 */4 * * *' => 'every 4 hours at :15',
      '0 7 * * *' => 'daily at 07:00',
      '30 18 * * *' => 'daily at 18:30',
      '0 7,19 * * *' => 'daily at 07:00 and 19:00',
      '0,30 9 * * *' => 'daily at 09:00 and 09:30',
      '0 9-17 * * *' => 'hourly at :00 from 09:00 to 17:00',
      '0,30 9-17 * * *' => 'hourly at :00 and :30 from 09:00 to 17:30',
      '*/15 9-17 * * *' => 'every 15 minutes from 09:00 to 17:45',
      '*/20 8-18 * * *' => 'every 20 minutes from 08:00 to 18:40',
      '* 9-17 * * *' => 'every minute from 09:00 to 17:59'
    }.each do |cron, text|
      it "humanizes #{cron.inspect} as #{text.inspect}" do
        expect(humanize(cron)).to eq(text)
      end
    end
  end

  describe 'day shapes' do
    {
      '0 8 * * 0' => 'weekly on Sunday at 08:00',
      '0 8 * * 7' => 'weekly on Sunday at 08:00',
      '0 8 * * MON' => 'weekly on Monday at 08:00',
      '0 8 * * 1,4' => 'weekly on Monday and Thursday at 08:00',
      '0 8 * * 1-3' => 'weekly on Monday through Wednesday at 08:00',
      '0 9 * * 1-5' => 'weekdays at 09:00',
      '0 9 * * mon-fri' => 'weekdays at 09:00',
      '0 10 * * 0,6' => 'weekends at 10:00',
      '30 2 15 * *' => 'monthly on day 15 at 02:30',
      '0 6 1,15 * *' => 'monthly on days 1 and 15 at 06:00',
      '0 4 15 3 *' => 'yearly on March 15 at 04:00',
      '0 4 1 JAN *' => 'yearly on January 1 at 04:00',
      '*/10 * * * 1-5' => 'every 10 minutes on weekdays',
      '35 * * * 0' => 'hourly at :35 on Sunday',
      '0 9-17 * * 1-5' => 'hourly at :00 from 09:00 to 17:00 on weekdays',
      '0 * 1 * *' => 'every hour on day 1 of the month',
      '*/15 9-17 * * 1-5' => 'every 15 minutes from 09:00 to 17:45 on weekdays',
      '0 9 * 6 *' => 'daily at 09:00 in June',
      '0 9 * 6-8 *' => 'daily at 09:00 in June through August',
      '0 9 * 1,7 1' => 'weekly on Monday at 09:00 in January and July',
      '0 9 1 1,7 *' => 'monthly on day 1 at 09:00 in January and July',
      '0 9 1-7 3 *' => 'monthly on days 1 through 7 at 09:00 in March',
      '*/10 * * DEC *' => 'every 10 minutes in December'
    }.each do |cron, text|
      it "humanizes #{cron.inspect} as #{text.inspect}" do
        expect(humanize(cron)).to eq(text)
      end
    end
  end

  describe 'extensions fugit accepts' do
    {
      '@hourly' => 'every hour',
      '@daily' => 'daily at midnight',
      '@midnight' => 'daily at midnight',
      '@weekly' => 'weekly on Sunday at 00:00',
      '@monthly' => 'monthly on day 1 at 00:00',
      '@yearly' => 'yearly on January 1 at 00:00',
      '@annually' => 'yearly on January 1 at 00:00',
      '0 7 * * * America/Chicago' => 'daily at 07:00 (America/Chicago)',
      '0 0 * * * UTC' => 'daily at midnight (UTC)',
      '0 0 7 * * *' => 'daily at 07:00',
      '0 30 6 * * 1 Europe/Stockholm' => 'weekly on Monday at 06:30 (Europe/Stockholm)',
      '0 0 8 * * MON' => 'weekly on Monday at 08:00',
      '*/30 * * * * *' => 'every 30 seconds',
      '* * * * * *' => 'every second'
    }.each do |cron, text|
      it "humanizes #{cron.inspect} as #{text.inspect}" do
        expect(humanize(cron)).to eq(text)
      end
    end
  end

  describe 'shapes it does not describe' do
    [
      '15 3 */2 * 1-5',     # stepped day of month
      '0 0 1 * 1',          # day of month and day of week both restricted (cron ORs them)
      '0 0 * */3 *',        # stepped months
      '*/10 9,17 * * *',    # stepped minutes over an hour list
      '*/10 9-11,14-17 * * *', # stepped minutes over several hour ranges
      '*/10 */2 * * *',     # stepped minutes over stepped hours
      '0 0 L * *',          # fugit's last-day extension
      '0 0 * * 1#2',        # nth weekday
      '1-5/2 * * * *',      # stepped range
      '60 * * * *',         # out of range minute
      '0 24 * * *',         # out of range hour
      '0 0 32 * *',         # out of range day
      '0 0 * * 8',          # out of range weekday
      '0 0 * * BOGUS',      # unknown name
      '15 * * * * *',       # seconds other than zero
      'every day at five',  # natural language
      '0 0 * *',            # too few fields
      '',
      nil
    ].each do |cron|
      it "returns nil for #{cron.inspect}" do
        expect(humanize(cron)).to be_nil
      end
    end
  end

  describe '.every' do
    {
      '45m' => 'every 45 minutes',
      '1h' => 'every hour',
      '1h30m' => 'every 1 hour 30 minutes',
      '2d' => 'every 2 days',
      '1w' => 'every week',
      '30s' => 'every 30 seconds',
      '45 minutes' => 'every 45 minutes',
      '2 hours and 30 minutes' => 'every 2 hours and 30 minutes',
      ['30s', { 'first_in' => '120s' }] => 'every 30 seconds'
    }.each do |value, text|
      it "humanizes #{value.inspect} as #{text.inspect}" do
        expect(described_class.every(value)).to eq(text)
      end
    end

    it 'returns nil without a value' do
      expect(described_class.every(nil)).to be_nil
      expect(described_class.every([])).to be_nil
    end
  end
end
