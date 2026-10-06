# scripts/poll_telegram_banner.rb
require "net/http"
require "json"
require "date"
require "time"
require "cgi"

ENV["TZ"] = "Europe/Kiev"

CHANNEL_URL = "https://t.me/s/poltavaoe"
POE_URL = "https://www.poe.pl.ua/disconnection/power-outages/"
OUTPUT_FILE = "data/poltava_status.json"

MONTHS = {
  "січня" => 1, "лютого" => 2, "березня" => 3, "квітня" => 4,
  "травня" => 5, "червня" => 6, "липня" => 7, "серпня" => 8,
  "вересня" => 9, "жовтня" => 10, "листопада" => 11, "грудня" => 12
}.freeze

DATE_REGEX = /(\d{1,2})\s+(#{MONTHS.keys.join("|")})\s+(\d{4})\s+року/
# Posts about the hourly outage schedule come in at least two wordings:
#   "На 29 вересня 2026 року застосування графіка погодинного відключення ... не прогнозується"
#   "... в Полтавській області 6 жовтня 2026 року з 15:00 по 23:59 запроваджений ГПВ в обсязі 1 черги"
SCHEDULE_TOPIC_REGEX = /застосування графіка погодинного відключення|\bГПВ\b|графік\S* погодинн/i
NOT_EXPECTED_REGEX = /не прогнозується/i
TIME_WINDOW_REGEX = /з\s+(\d{1,2}:\d{2})\s+по\s+(\d{1,2}:\d{2})/
QUEUES_REGEX = /в обсязі\s+(\d+)\s+черг/i

# poe.pl.ua table "Порядок відключення черг": 12 rows (1.1 ... 6.2) x 48 half-hour cells.
# light_1 = power on, light_2 = outage, light_3 = outage possible.
TABLE_REGEX = %r{<table[^>]*turnoff-scheduleui-table[^>]*>.*?</table>}m
TABLE_DATE_REGEX = /(\d{1,2})\s+(#{MONTHS.keys.join("|")})\s+(\d{4})\s+\d{1,2}:\d{2}/
KIND_BY_CLASS = { "1" => "on", "2" => "off", "3" => "maybe" }.freeze
SLOT_MINUTES = 30
SLOTS_PER_DAY = 24 * 60 / SLOT_MINUTES

def fetch_html(url)
  uri = URI(url)
  response = Net::HTTP.get_response(uri, { "User-Agent" => "Mozilla/5.0 (svitlo-tut parser)" })
  raise "HTTP #{response.code} from #{uri.host}" unless response.is_a?(Net::HTTPSuccess)

  response.body.force_encoding("UTF-8").scrub
end

def clean_text(raw)
  CGI.unescapeHTML(raw.gsub(%r{<br\s*/?>}, "\n").gsub(/<[^>]+>/, "")).gsub("\u00A0", " ").strip
end

def extract_schedule_posts(html)
  html.scan(%r{tgme_widget_message_text[^>]*>(.*?)</div>}m).flatten
    .map { |raw| clean_text(raw) }
    .select { |text| text.match?(SCHEDULE_TOPIC_REGEX) }
end

def parse_banner(text)
  date_match = text.match(DATE_REGEX)
  return nil unless date_match

  day, month_name, year = date_match.captures
  date = Date.new(year.to_i, MONTHS.fetch(month_name), day.to_i)

  entry = { date: date.to_s, applies: !text.match?(NOT_EXPECTED_REGEX), raw_text: text }

  if entry[:applies]
    windows = text.scan(TIME_WINDOW_REGEX).map { |from, to| { from: from, to: to } }
    entry[:windows] = windows unless windows.empty?

    queues = text[QUEUES_REGEX, 1]
    entry[:queues_count] = queues.to_i if queues
  end

  entry
end

def slot_time(index)
  hours, minutes = (index * SLOT_MINUTES).divmod(60)
  format("%02d:%02d", hours, minutes)
end

def kinds_to_intervals(kinds)
  index = 0
  kinds.slice_when { |a, b| a != b }.each_with_object([]) do |run, acc|
    acc << { from: slot_time(index), to: slot_time(index + run.size), kind: run.first } unless run.first == "on"
    index += run.size
  end
end

# Returns { date: "YYYY-MM-DD", queues: { "3.1" => [{from:, to:, kind:}] } } or nil.
def parse_schedule_table(html)
  table = html[TABLE_REGEX]
  return nil unless table

  queues = {}
  current_queue = nil
  table.scan(%r{<tr[^>]*>(.*?)</tr>}m).flatten.each do |row|
    subqueue = row[/turnoff-scheduleui-table-subqueue[^>]*>\s*(\d)\s*</, 1]
    next unless subqueue

    current_queue = row[/turnoff-scheduleui-table-queue[^>]*>\s*(\d)\s*черга/, 1] || current_queue
    kinds = row.scan(/class="light_(\d)"/).flatten.map { |c| KIND_BY_CLASS.fetch(c, "on") }
    next unless kinds.size == SLOTS_PER_DAY

    queues["#{current_queue}.#{subqueue}"] = kinds_to_intervals(kinds)
  end

  return nil unless queues.size == 12
  return nil if queues.values.all?(&:empty?) # table not filled in yet

  { date: table_date(html, table).to_s, queues: queues }
end

# Date from the "6 жовтня 2026 12:09" stamp after the table; falls back to today (Kyiv time).
def table_date(html, table)
  after_table = html.split(table, 2).last.to_s
  match = after_table.match(TABLE_DATE_REGEX)
  return Date.today unless match

  Date.new(match[3].to_i, MONTHS.fetch(match[2]), match[1].to_i)
end

def fetch_schedule_table
  parse_schedule_table(fetch_html(POE_URL))
rescue StandardError => e
  warn "Could not read poe.pl.ua table: #{e.class}: #{e.message}"
  nil
end

if $PROGRAM_NAME == __FILE__
  html = fetch_html(CHANNEL_URL)
  posts = extract_schedule_posts(html)
  parsed = posts.map { |text| parse_banner(text) }.compact

  # Posts on the channel page go oldest -> newest, so a later post for the same date wins.
  by_date = parsed.each_with_object({}) { |entry, acc| acc[entry[:date]] = entry }

  table = fetch_schedule_table
  if table && (entry = by_date[table[:date]]) && entry[:applies]
    entry[:queues] = table[:queues]
  elsif table
    warn "Table date #{table[:date]} has no matching ГПВ banner - ignoring table"
  end

  if by_date.empty?
    warn "No schedule posts found - keeping #{OUTPUT_FILE} untouched"
    exit 0
  end

  result = {
    checked_at: Time.now.utc.iso8601,
    days: by_date.values.sort_by { |d| d[:date] }
  }

  File.write(OUTPUT_FILE, JSON.pretty_generate(result))
  puts "Saved #{result[:days].size} day(s) to #{OUTPUT_FILE}"
  puts JSON.pretty_generate(result)
end