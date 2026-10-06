# scripts/poll_telegram_banner.rb
require "net/http"
require "json"
require "date"
require "time"
require "cgi"

CHANNEL_URL = "https://t.me/s/poltavaoe"
OUTPUT_FILE = "data/poltava_status.json"

MONTHS = {
  "січня" => 1, "лютого" => 2, "березня" => 3, "квітня" => 4,
  "травня" => 5, "червня" => 6, "липня" => 7, "серпня" => 8,
  "вересня" => 9, "жовтня" => 10, "листопада" => 11, "грудня" => 12
}.freeze

DATE_REGEX = /(\d{1,2})\s+(#{MONTHS.keys.join("|")})\s+(\d{4})\s+року/
SCHEDULE_TOPIC_REGEX = /застосування графіка погодинного відключення|\bГПВ\b|графік\S* погодинн/i
NOT_EXPECTED_REGEX = /не прогнозується/i
TIME_WINDOW_REGEX = /з\s+(\d{1,2}:\d{2})\s+по\s+(\d{1,2}:\d{2})/
QUEUES_REGEX = /в обсязі\s+(\d+)\s+черг/i

def fetch_html(url)
  uri = URI(url)
  response = Net::HTTP.get_response(uri)
  raise "Telegram returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  response.body.force_encoding("UTF-8")
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

html = fetch_html(CHANNEL_URL)
posts = extract_schedule_posts(html)
parsed = posts.map { |text| parse_banner(text) }.compact

# Posts on the channel page go oldest -> newest, so a later post for the same date wins.
by_date = parsed.each_with_object({}) { |entry, acc| acc[entry[:date]] = entry }

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