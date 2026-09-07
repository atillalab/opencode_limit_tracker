#!/usr/bin/env ruby

require "date"
require "json"
require "net/http"
require "time"
require "uri"

APP_NAME = "opencode_limit_tracker".freeze
ENDPOINT = "https://opencode.ai/zen/go/v1/usage".freeze
TIMEOUT = 12

def help_text
  <<~TEXT
    Usage: opencode_limit_tracker.rb [--json] [--refresh] [--help]

    Options:
      --json             Output machine-readable JSON only.
      --refresh          Force a fresh request to OpenCode's usage endpoint.
      -h, --help         Show this help message.
  TEXT
end

def options(argv)
  result = { json: false, refresh: false }
  argv.each do |arg|
    case arg
    when "--json" then result[:json] = true
    when "--refresh" then result[:refresh] = true
    when "-h", "--help" then puts help_text; exit 0
    else abort "Unknown option: #{arg}\n\n#{help_text}"
    end
  end
  result
end

def data_dir
  root = ENV["XDG_DATA_HOME"]
  root = File.expand_path("~/.local/share") if root.nil? || root.empty?
  File.join(root, "opencode")
end

def auth_key
  paths = []
  paths << File.expand_path(ENV["OPENCODE_AUTH_FILE"]) if ENV["OPENCODE_AUTH_FILE"]
  paths.concat([File.join(data_dir, "auth.json"), File.expand_path("~/.config/opencode/auth.json")])
  path = paths.uniq.find { |candidate| File.file?(candidate) }
  return nil unless path
  credential = JSON.parse(File.read(path))["opencode-go"]
  key = credential.is_a?(Hash) && credential["key"]
  key if key.is_a?(String) && !key.empty?
rescue Errno::EACCES, Errno::ENOENT, JSON::ParserError
  nil
end

def fetch_usage
  key = auth_key
  raise "OpenCode Go credential not found in auth.json" unless key
  uri = URI(ENDPOINT)
  request = Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer #{key}"
  request["User-Agent"] = "#{APP_NAME}/0.1"
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
                             open_timeout: TIMEOUT, read_timeout: TIMEOUT) { |http| http.request(request) }
  raise "OpenCode usage endpoint returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
  usage = JSON.parse(response.body)["usage"]
  raise "OpenCode usage response did not contain usage windows" unless usage.is_a?(Hash)
  windows = {}
  %w[rolling weekly monthly].each do |name|
    item = usage[name]
    next unless item.is_a?(Hash) && item["status"].is_a?(String) && item["percent"].is_a?(Numeric) && item["resetsAt"].is_a?(String)
    windows[name] = { "status" => item["status"], "percent_used" => item["percent"],
                      "left_percent" => [[100.0 - item["percent"], 0.0].max, 100.0].min,
                      "resets_at" => item["resetsAt"] }
  end
  raise "OpenCode usage response did not contain a supported limit window" if windows.empty?
  { "windows" => windows, "fetched_at" => Time.now.iso8601 }
rescue JSON::ParserError
  raise "OpenCode usage endpoint returned invalid JSON"
rescue SocketError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET => e
  raise "Could not reach OpenCode usage endpoint (#{e.class})"
end

def snapshot_path
  File.join(data_dir, "limit_tracker_daily_snapshot.json")
end

def load_snapshot
  return nil unless File.file?(snapshot_path)
  snapshot = JSON.parse(File.read(snapshot_path))
  return nil unless snapshot.is_a?(Hash) && snapshot["snapshot_date"] == Date.today.iso8601
  weekly = snapshot.dig("current_usage", "windows", "weekly")
  return nil if weekly && Time.parse(weekly["resets_at"]) <= Time.now
  snapshot
rescue Errno::EACCES, Errno::ENOENT, JSON::ParserError, ArgumentError
  nil
end

def save_snapshot(snapshot)
  Dir.mkdir(data_dir) unless Dir.exist?(data_dir)
  File.write(snapshot_path, JSON.pretty_generate(snapshot))
rescue Errno::EACCES, Errno::EPERM, Errno::ENOENT => e
  warn "Warning: could not persist daily snapshot (#{e.message}); continuing without cache."
end

def weekly_metrics(window)
  return {} unless window
  reset = Time.parse(window["resets_at"])
  days = (Date.parse(reset.getlocal.to_date.iso8601) - Date.today).to_i + 1
  days = 1 if days < 1
  daily = window["left_percent"].to_f / days
  { "weekly_reset_date" => reset.getlocal.to_date.iso8601, "weekly_context_left_percent" => window["left_percent"],
    "days_until_weekly_reset" => days, "daily_context_budget_percent" => daily,
    "weekly_context_after_today_budget_percent" => window["left_percent"] - daily }
rescue ArgumentError, TypeError
  { "weekly_context_left_percent" => window["left_percent"] }
end

def build_result(current, snapshot, source)
  weekly = current.dig("windows", "weekly")
  baseline = snapshot && snapshot.dig("baseline_usage", "windows", "weekly")
  baseline ||= weekly
  now = weekly_metrics(weekly)
  morning = weekly_metrics(baseline)
  spent = baseline && weekly ? [baseline["left_percent"] - weekly["left_percent"], 0].max : nil
  budget = morning["daily_context_budget_percent"]
  spent_share = spent && budget && budget.positive? ? (spent / budget) * 100.0 : nil
  { "provider" => "opencode", "source" => source, "fetched_at" => current["fetched_at"],
    "weekly_reset_date" => now["weekly_reset_date"], "weekly_context_left_percent" => weekly && weekly["left_percent"],
    "baseline_weekly_reset_date" => morning["weekly_reset_date"], "baseline_weekly_context_left_percent" => baseline && baseline["left_percent"],
    "days_until_weekly_reset" => morning["days_until_weekly_reset"], "daily_context_budget_percent" => budget,
    "weekly_context_after_today_budget_percent" => morning["weekly_context_after_today_budget_percent"],
    "today_spent_percent" => spent, "today_left_percent" => spent_share.nil? ? nil : [100.0 - spent_share, 0].max,
    "limits" => current["windows"] }
end

def pct(value)
  value.nil? ? "unavailable" : format("%.0f%%", value)
end

def reset_label(window)
  window ? Time.parse(window["resets_at"]).getlocal.strftime("%H:%M on %d %b") : "unavailable"
rescue ArgumentError, TypeError
  "unavailable"
end

def print_human(result, snapshot)
  spent = result["today_spent_percent"]
  budget = result["daily_context_budget_percent"]
  share = spent && budget && budget.positive? ? spent / budget * 100.0 : nil
  weekly = result.dig("limits", "weekly")
  puts "OpenCode usage"
  puts format("  Today's budget: %s spent, %s left today (%s of %s daily budget used)", pct(share), pct(result["today_left_percent"]), pct(spent), pct(budget))
  puts format("  Weekly limit now: %s left (resets %s)", pct(result["weekly_context_left_percent"]), reset_label(weekly))
  captured = snapshot && snapshot["captured_at"] ? " (captured #{Time.parse(snapshot["captured_at"]).getlocal.strftime("%H:%M")})" : ""
  puts format("  Morning baseline: %s left%s", pct(result["baseline_weekly_context_left_percent"]), captured)
  puts format("  Daily budget: %s", pct(budget))
  { "rolling" => "Rolling limit", "monthly" => "Monthly limit" }.each do |name, label|
    window = result.dig("limits", name)
    puts format("  %s: %s left (resets %s)", label, pct(window["left_percent"]), reset_label(window)) if window
  end
  puts "\nTIP\n  OpenCode Go usage is read from OpenCode's authenticated usage endpoint; local session data is not used to invent quota values."
end

opts = options(ARGV)
snapshot = load_snapshot
live = begin
  fetch_usage
rescue StandardError => e
  warn "Warning: #{e.message}; using the latest cached OpenCode usage if available."
  nil
end
current = live || (snapshot && snapshot["current_usage"])
abort "No live OpenCode usage and no cached OpenCode usage available." unless current
if live
  if snapshot.nil? || snapshot.dig("baseline_usage", "windows", "weekly").nil?
    snapshot = { "snapshot_date" => Date.today.iso8601, "captured_at" => Time.now.iso8601, "baseline_usage" => live }
  end
  snapshot["current_usage"] = live
  save_snapshot(snapshot)
end
result = build_result(current, snapshot, live ? "opencode_usage_api" : "cached_opencode_usage_api")
opts[:json] ? puts(JSON.generate(result)) : print_human(result, snapshot)
