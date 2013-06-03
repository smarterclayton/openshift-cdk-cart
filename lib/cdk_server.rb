require 'sinatra'
require 'httpclient'
require 'uri'
require 'safe_yaml'
require 'delegate'
require 'haml'
require 'forwardable'
require 'monitor'

ARCHIVE_EXT = ".zip"

helpers do
  def url_with_path(path)
    u = URI.parse(request.url)
    u.path = path
    u.query = nil
    u.fragment = nil
    u
  end

  def latest_cart_manifest_url
    url_with_path('/cartridge.yml')
  end

  def cart_manifest_url(commit='master')
    url_with_path("/manifest/#{commit}")
  end

  def cart_build_manifest_url(commit)
    url_with_path("/build/manifest/#{commit}")
  end

  def cart_archive_url(name, commit)
    url_with_path("/archive/#{URI.escape(commit)}/#{URI.escape(name)}.zip")
  end

  def cart_build_url(name, commit)
    url_with_path("/build/archive/#{URI.escape(commit)}/#{URI.escape(name)}#{ARCHIVE_EXT}")
  end

  def cdk_password
    @cdk_password ||= begin
      s = ENV['CDK_PASSWORD'] || ""
      s.empty? ? nil : s
    end
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

  def protected!
    return if authorized?
    headers['WWW-Authenticate'] = 'Basic realm="admin/CDK_PASSWORD"'
    halt 401, "Not authorized, please login with 'admin' and the value of the CDK_PASSWORD environment variable\n"
  end

  def authorized?
    return true if cdk_password.nil? 
    @auth ||=  Rack::Auth::Basic::Request.new(request.env)
    @auth.provided? and @auth.basic? and @auth.credentials and @auth.credentials == ['admin', cdk_password]
  end  
end

get '/' do
  redirect "/cartridge.yml" if request.env['HTTP_X_OPENSHIFT_CARTRIDGE_DOWNLOAD']

  commit = params[:from] || 'master'
  gitrepo = GitRepo.new(repo_path, commit)
  cart = CartInstance.find(gitrepo, commit) rescue nil
  dir = BuildDirectory.new(build_root_dir)

  haml :index, :format => :html5, :locals => {:cart => cart, :repo => gitrepo, :from => commit, :builds => dir.builds, :has_password => !cdk_password.nil? }
end

get '/cartridge.yml' do
  cart = CartInstance.find(repo)

  headers 'Content-Type' => 'text/plain'
  cart.manifest_with_source(cart_archive_url(cart.name, cart.commit))
end

get '/build/archive/:commit/*?' do
  cart = CartInstance.find(repo, params[:commit])
  return [400, "This version of the cart is not buildable (it has no .openshift/action_hooks/build file)."] unless cart.buildable?

  commit = cart.commit
  dir = BuildDirectory.new(build_root_dir)
  return [404, "There is no build for this commit"] unless dir.has_build?(commit)  

  send_file dir.build_path(commit)
end

post '/build' do
  protected!

  cart = CartInstance.find(repo, params[:commit])
  return [400, "This version of the cart is not buildable (it has no .openshift/action_hooks/build file)."] unless cart.buildable?

  commit = cart.commit
  
  dir = BuildDirectory.new(build_root_dir)
  if dir.has_build?(commit)
    [200, "A build already exists for this commit"]
  else
    headers 'Content-Type' => 'text/plain'
    tmpdir = dir.working_dir(commit)
    destination = dir.build_path(commit)
    ShellJob.new(<<-END).run
      set -e
      {
      (
        echo "Build of commit #{commit} starting now ..."
        echo
        cd #{repo.dir}
        flock -n -e 200
        # prepare directory
        mkdir -p #{tmpdir}
        git archive --format=tar #{commit} | (cd #{tmpdir} && tar --warning=no-timestamp -xf -)

        # build
        cd #{tmpdir}
        ./.openshift/action_hooks/build

        echo
        echo "Creating build archive ..."

        set +e
        if ( zip -r #{destination} * ); then
          rm -rf #{tmpdir}
        else
          rm -rf #{tmpdir}
          echo "Build failed"
          exit 1
        fi
        set -e

        du -h #{destination}
        echo 
        echo "Build complete"

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

get '/build/manifest/:commit' do
  cart = CartInstance.find(repo, params[:commit])

  headers 'Content-Type' => 'text/plain'
  cart.manifest_with_source(cart_build_url(cart.name, cart.commit))
end

get '/archive/:commit/:name.?:format?' do
  commit = params[:commit] || 'master'
  format = {'zip' => :zip, 'tar.gz' => :'tar.gz'}[params[:format]]

  redirect "/archive/#{URI.escape(commit)}/#{URI.escape(params[:name])}.tar.gz" unless format

  CartInstance.find(repo, commit).open(format)
end

class BuildDirectory
  attr_accessor :dir

  def initialize(dir)
    @dir = File.expand_path(dir)
  end

  def builds
    @builds ||= Dir[build_path('*')].map do |f|
      fname = File.basename(f)
      commit = commit_for_build(fname)
      [commit, File.mtime(f), as_human_size(File.size(f))]
    end
  end

  def has_build?(commit)
    File.exists? build_path(commit)
  end

  def build_path(commit)
    File.join(@dir, "build_#{commit}#{ARCHIVE_EXT}")
  end

  def commit_for_build(name)
    if m = /\Abuild_(.+)\.zip\Z/.match(name)
      m[1]
    end
  end

  def working_dir(commit)
    File.join(@dir, "#{commit}")
  end

  protected
    PREFIX = %W(TB GB MB KB B).freeze

    def as_human_size( s )
      s = s.to_f
      i = PREFIX.length - 1
      while s > 500 && i > 0
        i -= 1
        s /= 1000
      end
      ((s > 9 || s.modulo(1) < 0.1 ? '%d' : '%.1f') % s) + ' ' + PREFIX[i]
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

  def referring_to(sha1)
    check_commit(sha1)
    (recent_branches.map{ |b| b[0] == sha1 ? b[1] : nil }.compact +
      command("git for-each-ref --format='%(objectname) %(refname:short)' refs/tags/").lines.to_a.map{ |l| l.split(/ /) }.select{ |t| t[0] == sha1 }.map{ |t| t[1] } - [sha1]).uniq.sort
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
    path = check_path(path)    
    m = Dir.chdir(dir) do 
      spec = "#{ref}:#{path}"
      contents = `git show #{spec}`
      raise PathAndCommitNotFound, spec unless $? == 0
      contents
    end
  end

  def has_path(path, ref=branch)
    check_commit(ref)
    path = check_path(path)
    Dir.chdir(dir){ `git cat-file -e #{ref}:#{path} 2>/dev/null` }
    $? == 0
  end

  protected
    COMMIT_ID = %r(\A[a-zA-Z_\-0-9\./]{1,50}\Z)

    def check_commit(*commits)
      commits.each{ |commit| raise IllegalCommitArgument, commit unless commit =~ COMMIT_ID }
    end

    def check_path(path)
      path = URI.parse(path).path
      raise InvalidPath if path.nil? or path.start_with?('/')
      path
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

  def buildable?
    @buildable ||= gitrepo.has_path('.openshift/action_hooks/build', commit)
  end

  def open(format=:zip)
    gitrepo.archive(commit, format)
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