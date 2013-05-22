require 'sinatra'
require 'httpclient'
require 'uri'
require 'safe_yaml'
require 'delegate'
require 'haml'
require 'forwardable'
require 'monitor'

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

  def repo_path
    ENV['REPO_PATH'] || "#{ENV['OPENSHIFT_HOMEDIR']}/git/#{ENV['OPENSHIFT_APP_NAME']}.git"
  end

  def repo
    @repo ||= GitRepo.new(repo_path)
  end

  def start_job(job)
    puts "Found JobQueue #{job.object_id}"
    @job = JobQueue.get << job
  end

  def build_root_dir
    ENV['OPENSHIFT_DATA_DIR'] || '/tmp'
  end
  def build_dir(commit)
    "#{build_root_dir}/#{commit}"
  end
end

get '/' do
  gitrepo = GitRepo.new(repo_path, params[:branch] || 'master')
  cart = CartInstance.find(gitrepo) rescue nil
  dir = BuildDirectory.new(build_root_dir)

  haml :index, :format => :html5, :locals => {:cart => cart, :repo => gitrepo, :branch => gitrepo.branch, :builds => dir.builds }
end

get '/cartridge.yml' do
  cart = CartInstance.find(repo)

  headers 'Content-Type' => 'text/plain'
  cart.manifest_with_source(cart_archive_url(cart.name, cart.commit))
end

get '/build/:commit' do
  cart = CartInstance.find(repo, params[:commit])

  tmpdir = build_dir(cart.commit)
  Dir.chdir(repo.dir) do
    ShellJob.new(<<-END).run
      set -e
      {
      (
        flock -n -e 200
        # prepare directory
        mkdir -p #{tmpdir}
        git archive --format=tar #{cart.commit} | (cd #{tmpdir} && tar --warning=no-timestamp -xf -)

        # build
        cd #{tmpdir}
        ./.openshift/action_hooks/build
        touch .success

      ) 200>/tmp/cdk_build.lock
      } 2>&1
    END
  end
end

post '/manifest' do
  redirect "/manifest/#{URI.escape(params[:commit])}"
end

get '/manifest/:commit' do
  cart = CartInstance.find(repo, params[:commit])

  headers 'Content-Type' => 'text/plain'
  cart.manifest_with_source(cart_archive_url(cart.name, cart.commit))
end

get '/archive/:commit/:name.?:format?' do
  commit = params[:commit] || 'master'
  format = {'zip' => :zip, 'tar.gz' => :'tar.gz'}[params[:format]]

  redirect "/archive/#{URI.escape(commit)}/#{URI.escape(params[:name])}.zip" unless format

  CartInstance.find(repo, commit).open(format)
end

class BuildDirectory
  attr_accessor :dir

  def initialize(dir)
    @dir = dir
  end

  def builds
    @builds ||= Dir["#{@dir}/*/.success"].map do |f|
      File.basename(File.dirname(f))
    end
  end
end

class GitRepo
  attr_accessor :dir, :branch

  IllegalCommitArgument = Class.new(StandardError)
  UnknownCommit = Class.new(StandardError)
  InvalidRepo = Class.new(StandardError)
  InvalidPath = Class.new(StandardError)
  PathAndCommitNotFound = Class.new(StandardError)

  def initialize(dir, branch='master')
    @dir = dir
    @branch = branch
  end

  def recent_commits(ref=branch, limit=10)
    check_commit(ref)
    @recent_commits ||= command("git log #{ref} --pretty=format:'%H\t%h\t%an\t%ar\t%s' -n #{limit.to_i}", UnknownCommit).lines.map{ |l| l.split(/\t/) }
  end

  def recent_branches(limit=30)
    @recent_branches ||= command("git for-each-ref --sort=-committerdate refs/heads/ --count=#{limit.to_i} --format='%(objectname)\t%(refname:short)\t%(objectname:short)\t%(authorname)\t%(authordate:relative)\t%(subject)'").lines.map{ |l| l.split(/\t/) }
  end

  def archive(ref, format=:zip)
    check_commit(ref)
    Dir.chdir(dir){ IO.popen("git archive --format=#{format} #{ref}") }
  end

  def sha(ref)
    check_commit(ref)
    command("git rev-parse #{ref}", UnknownCommit, ref).strip
  end

  def contents(path, ref=branch)
    check_commit(ref)
    path = URI.parse(path).path
    raise InvalidPath if path.nil? or path.start_with?('/')
    m = Dir.chdir(dir) do 
      spec = "#{ref}:#{path}"
      contents = `git show #{spec}`
      raise PathAndCommitNotFound, spec unless $? == 0
      contents
    end
  end

  protected
    COMMIT_ID = %r(\A[a-zA-Z_\-0-9\./]{1,50}\Z)

    def check_commit(*commits)
      commits.each{ |commit| raise IllegalCommitArgument, commit unless commit =~ COMMIT_ID }
    end

    def command(command, exc=InvalidRepo, exc_arg=nil)
      Dir.chdir(dir) do
        s = Kernel.send(:`, command)
        raise exc, exc_arg unless $? == 0
        s
      end.strip
    end    
end

class CartInstance
  extend Forwardable

  ManifestNotFound = Class.new(StandardError)
  EmptyManifest = Class.new(StandardError)

  def self.find(repo, commit='master')
    commit = repo.sha(commit)
    m = Manifest.parse(repo.contents('metadata/manifest.yml', commit))
    new(m, commit, repo)
  end

  attr_accessor :manifest, :gitrepo, :commit
  def_delegators :@manifest, :name, :display_name, :cart_version

  def initialize(manifest, commit, gitrepo)
    @manifest = manifest
    @commit = commit
    @gitrepo = gitrepo
  end

  def manifest_with_source(source)
    m = @manifest.yaml.clone
    if version = Gem::Version.new(m['Cartridge-Version'] || "0.0.1") rescue nil
      m['Cartridge-Version'] = "#{version}-#{commit[0,8]}"
    end
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

class ShellJob
  def initialize(cmd)
    @cmd = cmd
  end
  def run
    @done = false
    IO.popen(@cmd)
  end
  def done?
    @end
  end
  def end
    @end = true
  end
end

class JobQueue
  def self.get
    @queue ||= JobQueue.new(4)
  end
  def initialize(count)
    @jobs = []
    @job_lock = Monitor.new
  end
  def <<(job)
    @job_lock.synchronize do
      @jobs.delete_if{ |j| j.done? }
      puts "Got #{@jobs.length} jobs"
      raise "Job queue is full" if @jobs.length > 4
      @jobs << job
    end
    job
  end
end