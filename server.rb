require 'bundler'
Bundler.require

require 'haml'
require 'sinatra/reloader' if development?

uri = URI.parse(ENV["REDISTOGO_URL"] || "localhost:27017")
$redis = Redis.new(:host => uri.host, :port => uri.port, :password => uri.password)

API_URL = "https://api.github.com"
GIST_URL = "#{API_URL}/gists"
INDEX_GIST_ID = 4257908

class GistMarkdown
  include HTTParty
  format :plain
end

def get_rate_limit
  response = HTTParty.get("#{API_URL}/rate_limit")
  ret = JSON.parse(response.body)
  return "#{ret['rate']['remaining']}/#{ret['rate']['limit']}"
end

def fetch_and_cache_gist(id)
  print "getting #{id}: "
  response = HTTParty.get("#{GIST_URL}/#{id}")
  puts response.message
  ret = JSON.parse(response.body)
  $redis.hmset("gist:#{id}", "content", ret.to_json, "cached", true)
  $redis.expire("gist:#{id}", 1800)
  $redis.sadd("gists", id) unless $redis.sismember("gists", id)
  return ret
end

def fetch_and_cache_render(id)
  gist_content = get_gist_contents(id, true)

  print "rendering #{id}: "
  response = GistMarkdown.post("#{API_URL}/markdown/raw", {body: gist_content, headers: {"Content-Type" => "text/x-markdown"}})
  text = response.parsed_response
  puts response.message

  $redis.hset("gist:#{id}", "render", text)
  return text
end

def build_and_cache_posts
  index = get_gist_contents(INDEX_GIST_ID).first
  index.split("\n").map do |post_id|
    get_rendered_gist(post_id, true)
  end
end

def get_gist(id, force_uncached=false)
  if $redis.hget("gist:#{id}", "cached") and !force_uncached
    puts "getting #{id}: cached"
    return JSON.parse($redis.hget("gist:#{id}", "content"))
  else
    return fetch_and_cache_gist(id)
  end
end

def get_gist_files(id, force_uncached=false)
  gist = get_gist(id, force_uncached)
  return gist['files']
end

def get_gist_contents(id, force_uncached=false)
  files = get_gist_files(id, force_uncached)
  files.keys.map { |file| files[file]['content'] }.reduce(:+)
end

def get_rendered_gist(id, force_uncached=false)
  if rendered = $redis.hget("gist:#{id}", "render") and !force_uncached
    puts "rendering #{id}: cached"
    return rendered
  else
    return fetch_and_cache_render(id)
  end
end

def build_posts
  index = get_gist_contents(INDEX_GIST_ID, true)
  index.split("\n").map do |post_id|
    get_rendered_gist(post_id, true)
  end
end

def get_posts
  index = get_gist_contents(INDEX_GIST_ID)
  index.split("\n").map do |post_id|
    get_rendered_gist(post_id)
  end
end

get '/' do
  posts = get_posts
  haml :index, locals: {posts: posts}
end

get '/rebuild' do
  build_posts
  redirect to '/'
end
