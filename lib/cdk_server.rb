require 'sinatra'
require 'httpclient'
require 'uri'
require 'safe_yaml'
require 'delegate'
require 'haml'
require 'forwardable'

helpers do
  def latest_cart_manifest_url
    u = URI.parse(request.url)
    u.path = '/cartridge.yml'
    u.query = nil
    u.fragment = nil
    u.to_s  end

  def cart_manifest_url(commit='master')
    u = URI.parse(request.url)
    u.path = "/manifest/#{commit}"
    u.query = nil
    u.fragment = nil
    u.to_s
  end

  def cart_archive_url(name, commit)
    url = URI.parse(request.url)
    url.path = "/archive/#{URI.escape(commit)}/#{URI.escape(name)}.zip"
    url.query = nil
    url.fragment = nil
    url.to_s    
  end
end

get '/' do
  cart = CartInstance.find rescue nil

  haml :index, :format => :html5, :locals => {:cart => cart}
end

get '/cartridge.yml' do
  cart = CartInstance.find

  headers 'Content-Type' => 'text/plain'
  cart.manifest_with_source(cart_archive_url(cart.name, cart.commit))
end

get '/manifest/:commit' do
  cart = CartInstance.find(params[:commit])


  headers 'Content-Type' => 'text/plain'
  cart.manifest_with_source(cart_archive_url(cart.name, cart.commit))
end

get '/archive/:commit/:name.?:format?' do
  commit = params[:commit] || 'master'
  format = {'zip' => :zip, 'tar.gz' => :'tar.gz'}[params[:format]]

  redirect "/archive/#{URI.escape(commit)}/#{URI.escape(params[:name])}.zip" unless format

  CartInstance.find(commit).open(format)
end

class CartInstance
  extend Forwardable

  IllegalCommitArgument = Class.new(StandardError)
  UnknownCommit = Class.new(StandardError)
  ManifestNotFound = Class.new(StandardError)
  EmptyManifest = Class.new(StandardError)

  COMMIT_ID = %r(\A[a-zA-Z_\-0-9\./]{1,50}\Z)

  def self.find(treeid='master')
    raise IllegalCommitArgument, treeid unless treeid =~ COMMIT_ID

    dir = "#{ENV['OPENSHIFT_HOMEDIR']}/git/#{ENV['OPENSHIFT_APP_NAME']}.git"
    commit = treeid
    m = Dir.chdir(dir) do 
      commit = `git rev-parse #{commit}`
      raise UnknownCommit, treeid unless $? == 0
      commit.strip!
      spec = "#{commit}:metadata/manifest.yml"
      manifest = `git show #{spec}`
      raise ManifestNotFound, spec unless $? == 0
      Manifest.parse(manifest)
    end
    new(m, commit, dir)
  end

  attr_accessor :manifest, :gitrepo, :commit
  def_delegators :@manifest, :name, :display_name, :cart_version

  def initialize(manifest, commit, gitrepo)
    @manifest = manifest
    @commit = commit
    @gitrepo = gitrepo
  end

  def recent_commits(limit=10)
    Dir.chdir(gitrepo) do 
      lines = `git log --pretty=format:'%H\t%h\t%an\t%ar\t%s' -n #{limit.to_i}`
      lines = "" if $? != 0
      lines.lines.map{ |l| l.split(/\t/) }
    end      
  end

  def open(format=:zip)
    Dir.chdir(gitrepo) do 
      puts "Generating #{commit} from #{gitrepo}"
      IO.popen("git archive --format=#{format} #{commit}")
    end
  end

  def manifest_with_source(source)
    m = @manifest.yaml.clone
    m['Source-Url'] = source.to_s
    m.to_yaml.gsub(/\A---\n/,'')
  end

  class Manifest
    def self.parse(contents)
      yaml = YAML.load(contents, nil, :safe => true, :raise_on_unknown_tag => true) or raise EmptyManifest
      new(yaml)
    end

    attr_accessor :yaml

    def initialize(yaml)
      @yaml = yaml
    end

    {'Name' => :name}.each_pair{ |k,v| define_method(v){ yaml[k] } }
    {'Display-Name' => :display_name}.each_pair{ |k,v| define_method(v){ yaml[k] } }
    {'Cartridge-Version' => :cart_version}.each_pair{ |k,v| define_method(v){ yaml[k] } }
  end  
end
