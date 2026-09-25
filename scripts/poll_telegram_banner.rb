# scripts/poll_telegram_banner.rb
require "net/http"
require "json"
require "date"

CHANNEL_URL = "https://t.me/s/poltavaoe"
OUTPUT_FILE = "data/poltava_status.json"

MONTHS = {
  "січня" => 1, "лютого" => 2, "березня" => 3, "квітня" => 4,
  "травня" => 5, "червня" => 6, "липня" => 7, "серпня" => 8,
  "вересня" => 9, "жовтня" => 10, "листопада" => 11, "грудня" => 12
}.freeze

def fetch_html(url)
  uri = URI(url)
  response = Net::HTTP.get(uri)
  response.force_encoding("UTF-8")
end

def extract_banner_posts(html)
  html.scan(/tgme_widget_message_text[^>]*>(.*?)<\/div>/m).flatten
    .map { |raw| raw.gsub("<br/>", "\n").gsub(/<[^>]+>/, "").gsub("&#33;", "!").gsub("&nbsp;", " ").strip }
    .select { |text| text.include?("застосування графіка погодинного відключення") }
end

def parse_banner(text)
  date_match = text.match(/На (\d{1,2}) (\S+) (\d{4}) року/)
  return nil unless date_match

  day, month_name, year = date_match.captures
  month = MONTHS[month_name]
  return nil unless month

  date = Date.new(year.to_i, month, day.to_i)
  applies = !text.include?("не прогнозується")

  { date: date.to_s, applies: applies, raw_text: text }
end

html = fetch_html(CHANNEL_URL)
posts = extract_banner_posts(html)
parsed = posts.filter_map { |text| parse_banner(text) }

by_date = parsed.each_with_object({}) { |entry, acc| acc[entry[:date]] = entry }

result = {
  checked_at: Time.now.utc.iso8601,
  days: by_date.values.sort_by { |d| d[:date] }
}

File.write(OUTPUT_FILE, JSON.pretty_generate(result))
puts "Saved #{result[:days].size} day(s) to #{OUTPUT_FILE}"
puts JSON.pretty_generate(result)