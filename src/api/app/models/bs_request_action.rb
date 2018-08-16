require 'api_exception'

class BsRequestAction < ApplicationRecord
  #### Includes and extends
  include ParsePackageDiff

  #### Constants
  VALID_SOURCEUPDATE_OPTIONS = ['update', 'noupdate', 'cleanup'].freeze

  #### Self config
  class DiffError < APIException; setup 404; end # a diff error can have many reasons, but most likely something within us
  class RemoteSource < APIException; end
  class RemoteTarget < APIException; end
  class InvalidReleaseTarget < APIException; end
  class LackingMaintainership < APIException
    setup 'lacking_maintainership', 403, 'Creating a submit request action with options requires maintainership in source package'
  end
  class NoMaintenanceProject < APIException; end
  class UnknownAttribute < APIException; setup 404; end
  class IncidentHasNoMaintenanceProject < APIException; end
  class NotSupported < APIException; end
  class SubmitRequestRejected < APIException; end
  class RequestRejected < APIException; setup 403; end
  class UnknownProject < APIException; setup 404; end
  class UnknownRole < APIException; setup 404; end
  class IllegalRequest < APIException; end
  class BuildNotFinished < APIException; end
  class UnknownTargetProject < APIException; end
  class UnknownTargetPackage < APIException; end
  class WrongLinkedPackageSource < APIException; end
  class MissingPatchinfo < APIException; end
  class VersionReleaseDiffers < APIException; end

  #### Attributes

  #### Associations macros (Belongs to, Has one, Has many)
  belongs_to :bs_request, touch: true
  has_one :bs_request_action_accept_info, dependent: :delete

  belongs_to :target_package_object, class_name: 'Package', foreign_key: 'target_package_id'
  belongs_to :target_project_object, class_name: 'Project', foreign_key: 'target_project_id'

  scope :bs_request_ids_of_involved_projects, ->(project_ids) { where(target_project_id: project_ids).select(:bs_request_id) }
  scope :bs_request_ids_of_involved_packages, ->(package_ids) { where(target_package_id: package_ids).select(:bs_request_id) }
  scope :bs_request_ids_by_source_projects, ->(project_name) { where(source_project: project_name).select(:bs_request_id) }

  scope :with_target_package, -> { where.not(target_package_id: nil) }
  scope :with_target_project, -> { where.not(target_project_id: nil) }

  #### Callbacks macros: before_save, after_save, etc.
  #### Scopes (first the default_scope macro if is used)

  #### Validations macros
  validates :sourceupdate, inclusion: { in: VALID_SOURCEUPDATE_OPTIONS, allow_nil: true }
  validate :check_sanity
  validates :type, uniqueness: {
    scope:      [:target_project, :target_package, :bs_request_id],
    conditions: -> { where.not(type: ['add_role', 'maintenance_incident']) }
  }

  before_validation :set_target_associations

  #### Class methods using self. (public and then private)

  def self.get_package_diff(path, query)
    path += "?#{query.to_query}"
    begin
      Backend::Connection.post(path, '', 'Timeout' => 30).body
    rescue Timeout::Error
      raise DiffError, "Timeout while diffing #{path}"
    rescue ActiveXML::Transport::Error => e
      raise DiffError, "The diff call for #{path} failed: #{e.summary}"
    end
  end

  def self.type_to_class_name(type_name)
    "BsRequestAction#{type_name.classify}".constantize
  end

  def self.find_sti_class(type_name)
    return super if type_name.nil?
    type_to_class_name(type_name) || super
  end

  def self.new_from_xml_hash(hash)
    classname = type_to_class_name(hash.delete('type'))

    # request actions of type group were official never supported
    # but there is build.opensuse.org which contains quite some of these
    # requests. However, it is not used there anymore, so dis-allow to create
    # new requests. But we do validate that the code is still working.
    # FIXME3.0: drop this code and drop these actions from database.
    raise ArgumentError, 'request actions of type group can not be created anymore' if classname == BsRequestActionGroup && !Rails.env.test?

    raise ArgumentError, 'unknown type' unless classname

    a = classname.new
    # now remove things from hash
    a.store_from_xml(hash)
    raise ArgumentError, "too much information #{hash.inspect}" if hash.present?
    a
  end

  #### To define class methods as private use private_class_method
  #### private

  #### Instance methods (public and then protected/private)
  def minimum_priority
    nil
  end

  def check_sanity
    if action_type.in?([:submit, :maintenance_incident, :maintenance_release, :change_devel])
      errors.add(:source_project, "should not be empty for #{action_type} requests") if source_project.blank?
      unless is_maintenance_incident?
        errors.add(:source_package, "should not be empty for #{action_type} requests") if source_package.blank?
      end
      errors.add(:target_project, "should not be empty for #{action_type} requests") if target_project.blank?
      if source_package == target_package && source_project == target_project
        if sourceupdate || updatelink
          errors.add(:target_package, 'No source changes are allowed, if source and target is identical')
        end
      end
    end
    errors.add(:target_package, 'is invalid package name') if target_package && !Package.valid_name?(target_package)
    errors.add(:source_package, 'is invalid package name') if source_package && !Package.valid_name?(source_package)
    errors.add(:target_project, 'is invalid project name') if target_project && !Project.valid_name?(target_project)
    errors.add(:source_project, 'is invalid project name') if source_project && !Project.valid_name?(source_project)

    # TODO: to be continued
  end

  def action_type
    self.class.sti_name
  end

  # convenience functions to check types
  def is_submit?
    false
  end

  def is_maintenance_release?
    false
  end

  def is_maintenance_incident?
    false
  end

  def matches_package?(source_or_target, pkg)
    send("#{source_or_target}_project") == pkg.project.name && send("#{source_or_target}_package") == pkg.name
  end

  def is_from_remote?
    Project.unscoped.is_remote_project?(source_project, true)
  end

  def store_from_xml(hash)
    source = hash.delete('source')
    if source
      self.source_package = source.delete('package')
      self.source_project = source.delete('project')
      self.source_rev = source.delete('rev')

      raise ArgumentError, "too much information #{source.inspect}" if source.present?
    end

    target = hash.delete('target')
    if target
      self.target_package = target.delete('package')
      self.target_project = target.delete('project')
      self.target_releaseproject = target.delete('releaseproject')
      self.target_repository = target.delete('repository')

      raise ArgumentError, "too much information #{target.inspect}" if target.present?
    end

    ai = hash.delete('acceptinfo')
    if ai
      self.bs_request_action_accept_info = BsRequestActionAcceptInfo.new
      bs_request_action_accept_info.rev = ai.delete('rev')
      bs_request_action_accept_info.srcmd5 = ai.delete('srcmd5')
      bs_request_action_accept_info.osrcmd5 = ai.delete('osrcmd5')
      bs_request_action_accept_info.xsrcmd5 = ai.delete('xsrcmd5')
      bs_request_action_accept_info.oxsrcmd5 = ai.delete('oxsrcmd5')

      raise ArgumentError, "too much information #{ai.inspect}" if ai.present?
    end

    o = hash.delete('options')
    if o
      self.sourceupdate = o.delete('sourceupdate')
      # old form
      self.sourceupdate = 'update' if sourceupdate == '1'
      # there is mess in old data ;(
      self.sourceupdate = nil unless sourceupdate.in?(VALID_SOURCEUPDATE_OPTIONS)

      self.updatelink = true if o.delete('updatelink') == 'true'
      self.makeoriginolder = o.delete('makeoriginolder')
      raise ArgumentError, "too much information #{s.inspect}" if o.present?
    end

    p = hash.delete('person')
    if p
      self.person_name = p.delete('name') { raise ArgumentError, 'a person without name' }
      self.role = p.delete('role')
      raise ArgumentError, "too much information #{p.inspect}" if p.present?
    end

    g = hash.delete('group')
    return unless g

    self.group_name = g.delete('name') { raise ArgumentError, 'a group without name' }
    raise ArgumentError, 'role already taken' if role
    self.role = g.delete('role')
    raise ArgumentError, "too much information #{g.inspect}" if g.present?
  end

  def xml_package_attributes(source_or_target)
    attributes = {}
    value = send "#{source_or_target}_project"
    attributes[:project] = value if value.present?
    value = send "#{source_or_target}_package"
    attributes[:package] = value if value.present?
    attributes
  end

  def render_xml_source(node)
    attributes = xml_package_attributes('source')
    attributes[:rev] = source_rev if source_rev.present?
    node.source attributes
  end

  def render_xml_target(node)
    attributes = xml_package_attributes('target')
    attributes[:releaseproject] = target_releaseproject if target_releaseproject.present?
    node.target attributes
  end

  def render_xml_attributes(node)
    return unless action_type.in?([:submit, :maintenance_incident, :maintenance_release, :change_devel])

    render_xml_source(node)
    render_xml_target(node)
  end

  def render_xml(builder)
    builder.action type: action_type do |action|
      render_xml_attributes(action)
      if sourceupdate || updatelink || makeoriginolder
        action.options do
          action.sourceupdate sourceupdate if sourceupdate
          action.updatelink 'true' if updatelink
          action.makeoriginolder 'true' if makeoriginolder
        end
      end
      bs_request_action_accept_info.render_xml(builder) unless bs_request_action_accept_info.nil?
    end
  end

  def set_acceptinfo(ai)
    self.bs_request_action_accept_info = BsRequestActionAcceptInfo.create(ai)
  end

  def notify_params(ret = {})
    ret[:action_id] = id
    ret[:type] = action_type.to_s
    ret[:sourceproject] = source_project
    ret[:sourcepackage] = source_package
    ret[:sourcerevision] = source_rev
    ret[:person] = person_name
    ret[:group] = group_name
    ret[:role] = role
    ret[:targetproject] = target_project
    ret[:targetpackage] = target_package
    ret[:targetrepository] = target_repository
    ret[:target_releaseproject] = target_releaseproject
    ret[:sourceupdate] = sourceupdate
    ret[:makeoriginolder] = makeoriginolder

    ret[:targetpackage] ||= source_package if action_type == :change_devel

    ret.keys.each do |k|
      ret.delete(k) if ret[k].nil?
    end
    ret
  end

  def contains_change?
    return sourcediff.present?
  rescue BsRequestAction::DiffError
    # if the diff can'be created we can't say
    # but let's assume the reason for the problem lies in the change
    return true
  end

  def sourcediff(_opts = {})
    ''
  end

  def webui_infos(opts = {})
    begin
      opts[:view] = 'xml'
      opts[:withissues] = true

      sd = sourcediff(opts)
    rescue DiffError, Project::UnknownObjectError, Package::UnknownObjectError => e
      return [{ error: e.message }]
    end
    diff = sorted_filenames_from_sourcediff(sd)
    if diff[0].empty?
      nil
    else
      diff
    end
  end

  def default_reviewers
    reviews = []
    return reviews unless target_project

    tprj = Project.get_by_name target_project
    if tprj.class == String
      raise RemoteTarget, 'No support to target to remote projects. Create a request in remote instance instead.'
    end
    tpkg = nil
    if target_package
      if is_maintenance_release?
        # use orignal/stripped name and also GA projects for maintenance packages.
        # But do not follow project links, if we have a branch target project, like in Evergreen case
        if tprj.find_attribute('OBS', 'BranchTarget')
          tpkg = tprj.packages.find_by_name target_package.gsub(/\.[^\.]*$/, '')
        else
          tpkg = tprj.find_package target_package.gsub(/\.[^\.]*$/, '')
        end
      elsif action_type.in?([:set_bugowner, :add_role, :change_devel, :delete])
        # target must exists
        tpkg = tprj.packages.find_by_name! target_package
      else
        # just the direct affected target
        tpkg = tprj.packages.find_by_name target_package
      end
    elsif source_package
      tpkg = tprj.packages.find_by_name source_package
    end

    if source_project
      # if the user is not a maintainer if current devel package, the current maintainer gets added as reviewer of this request
      if action_type == :change_devel && tpkg.develpackage && !User.current.can_modify_package?(tpkg.develpackage, 1)
        reviews.push(tpkg.develpackage)
      end

      unless is_maintenance_release?
        # Creating requests from packages where no maintainer right exists will enforce a maintainer review
        # to avoid that random people can submit versions without talking to the maintainers
        # projects may skip this by setting OBS:ApprovedRequestSource attributes
        if source_package
          spkg = Package.find_by_project_and_name source_project, source_package
          if spkg && !User.current.can_modify_package?(spkg)
            if  !spkg.project.find_attribute('OBS', 'ApprovedRequestSource') &&
                !spkg.find_attribute('OBS', 'ApprovedRequestSource')
              reviews.push(spkg)
            end
          end
        else
          sprj = Project.find_by_name source_project
          if sprj && !User.current.can_modify_project?(sprj) && !sprj.find_attribute('OBS', 'ApprovedRequestSource')
            reviews.push(sprj) unless sprj.find_attribute('OBS', 'ApprovedRequestSource')
          end
        end
      end
    end

    # find reviewers in target package
    reviews += find_reviewers(tpkg) if tpkg
    # project reviewers get added additionaly - might be dups
    reviews += find_reviewers(tprj) if tprj

    reviews.uniq
  end

  #
  # find default reviewers of a project/package via role
  #
  def find_reviewers(obj)
    # obj can be a project or package object
    reviewers = []

    reviewer_id = Role.hashed['reviewer'].id

    # check for reviewers in a package first
    if obj.class == Project
      obj.relationships.users.where(role_id: reviewer_id).pluck(:user_id).each do |r|
        reviewers << User.find(r)
      end
      obj.relationships.groups.where(role_id: reviewer_id).pluck(:group_id).each do |r|
        reviewers << Group.find(r)
      end
    elsif obj.class == Package
      obj.relationships.users.where(role_id: reviewer_id).pluck(:user_id).each do |r|
        reviewers << User.find(r)
      end
      obj.relationships.groups.where(role_id: reviewer_id).pluck(:group_id).each do |r|
        reviewers << Group.find(r)
      end
      reviewers += find_reviewers(obj.project)
    end

    reviewers
  end

  def request_changes_state(_state)
    # only groups care for now
  end

  def get_releaseproject(_pkg, _tprj)
    # only needed for maintenance incidents
    nil
  end

  def execute_accept(_opts)
    raise 'Needs to be reimplemented in subclass'
  end

  # after all actions are executed, the controller calls into every action a cleanup
  # the actions can "cache" in the opts their state to avoid duplicated work
  def per_request_cleanup(_opts)
    # does nothing by default
  end

  # this is called per action once it's verified that all actions in a request are
  # permitted.
  def create_post_permissions_hook(_opts)
    # does nothing by default
  end

  # general source cleanup, used in submit and maintenance_incident actions
  def source_cleanup
    source_project = Project.find_by_name(self.source_project)
    return unless source_project
    if (source_project.packages.count == 1 && ::Configuration.cleanup_empty_projects) || !source_package

      # remove source project, if this is the only package and not a user's home project
      splits = self.source_project.split(':')
      return if splits.count == 2 && splits[0] == 'home'

      source_project.commit_opts = { comment: bs_request.description, request: bs_request }
      source_project.destroy
      return "/source/#{self.source_project}"
    end
    # just remove one package
    source_package = source_project.packages.find_by_name!(self.source_package)
    source_package.commit_opts = { comment: bs_request.description, request: bs_request }
    source_package.destroy
    Package.source_path(self.source_project, self.source_package)
  end

  def check_maintenance_release(pkg, repo, arch)
    binaries = Xmlhash.parse(Backend::Api::BuildResults::Binaries.files(pkg.project.name, repo.name, arch.name, pkg.name))
    l = binaries.elements('binary')
    unless l && l.count > 0
      raise BuildNotFinished, "patchinfo #{pkg.name} is not yet build for repository '#{repo.name}'"
    end

    # check that we did not skip a source change of patchinfo
    data = Directory.hashed(project: pkg.project.name, package: pkg.name, expand: 1)
    verifymd5 = data['srcmd5']
    history = Xmlhash.parse(Backend::Api::BuildResults::Binaries.history(pkg.project.name, repo.name, pkg.name, arch.name))
    last = history.elements('entry').last
    return if last && last['srcmd5'].to_s == verifymd5.to_s

    raise BuildNotFinished, "last patchinfo #{pkg.name} is not yet build for repository '#{repo.name}'"
  end

  # rubocop:disable Metrics/CyclomaticComplexity
  # rubocop:disable Metrics/PerceivedComplexity
  def create_expand_package(packages, opts = {})
    newactions = []
    incident_suffix = ''
    if is_maintenance_release?
      # The maintenance ID is always the sub project name of the maintenance project
      incident_suffix = '.' + source_project.gsub(/.*:/, '')
    end

    found_patchinfo = false
    new_packages = []
    new_targets = []

    packages.each do |pkg|
      unless pkg.is_a? Package
        raise RemoteSource, 'No support for auto expanding from remote instance. You need to submit a full specified request in that case.'
      end
      # find target via linkinfo or submit to all.
      # FIXME: this is currently handling local project links for packages with multiple spec files.
      #        This can be removed when we handle this as shadow packages in the backend.
      tpkg = ltpkg    = pkg.name
      rev             = source_rev
      data            = nil
      missing_ok_link = false
      suffix          = ''
      tprj            = pkg.project

      while tprj == pkg.project
        data = Directory.hashed(project: tprj.name, package: ltpkg)
        e = data['linkinfo']

        if e
          suffix = ltpkg.gsub(/^#{Regexp.escape(e['package'])}/, '')
          ltpkg = e['package']
          tprj = Project.get_by_name(e['project'])

          missing_ok_link = true if e['missingok']
        else
          tprj = nil
        end
      end

      if target_package
        # manual specified
        tpkg = target_package
      elsif pkg.releasename && is_maintenance_release?
        # incidents created since OBS 2.8 should have this information already.
        tpkg = pkg.releasename
      elsif tprj.try(:is_maintenance_incident?) && is_maintenance_release?
        # fallback, how can we get rid of it?
        data = Directory.hashed(project: tprj.name, package: ltpkg)
        e = data['linkinfo']
        tpkg = e['package'] if e
      else
        # we need to get rid of it again ...
        tpkg = tpkg.gsub(/#{Regexp.escape(suffix)}$/, '') # strip distro specific extension
      end

      # maintenance incident actions need a releasetarget
      releaseproject = get_releaseproject(pkg, tprj)

      # overwrite target if defined
      tprj = Project.get_by_name(target_project) if target_project
      raise UnknownTargetProject, 'target project does not exist' unless tprj || is_maintenance_release?

      # do not allow release requests without binaries
      if is_maintenance_release? && pkg.is_patchinfo? && data && !opts[:ignore_build_state]
        # check for build state and binaries
        state = REXML::Document.new(Backend::Api::BuildResults::Status.version_releases(pkg.project.name))
        results = state.get_elements("/resultlist/result[@project='#{pkg.project.name}'')]")
        unless results
          raise BuildNotFinished, "The project'#{pkg.project.name}' has no building repositories"
        end
        versrel = {}
        results.each do |result|
          repo = result.attributes['repository']
          arch = result.attributes['arch']
          if result.attributes['dirty']
            raise BuildNotFinished, "The repository '#{pkg.project.name}' / '#{repo}' / #{arch} " \
                                    'needs recalculation by the schedulers'
          end
          if result.attributes['state'].in?(['finished', 'publishing'])
            raise BuildNotFinished, "The repository '#{pkg.project.name}' / '#{repo}' / #{arch}" \
                                    'did not finish the publish yet'
          end
          unless result.attributes['state'].in?(['published', 'unpublished'])
            raise BuildNotFinished, "The repository '#{pkg.project.name}' / '#{repo}' / #{arch} " \
                                    'did not finish the build yet'
          end

          # all versrel are the same
          versrel[repo] ||= {}
          result.get_elements('status').each do |status|
            package = status.attributes['package']
            vrel = status.attributes['versrel']
            next unless vrel
            if versrel[repo][package] && versrel[repo][package] != vrel
              raise VersionReleaseDiffers, "#{package} has a different version release in same repository"
            end
            versrel[repo][package] ||= vrel
          end
        end

        pkg.project.repositories.each do |repo|
          next unless repo
          firstarch = repo.architectures.first
          next unless firstarch

          # skip excluded patchinfos
          status = state.get_elements("/resultlist/result[@repository='#{repo.name}' and @arch='#{firstarch.name}']").first
          next if status && (s = status.get_elements("status[@package='#{pkg.name}']").first) && s.attributes['code'] == 'excluded'
          raise BuildNotFinished, "patchinfo #{pkg.name} is broken" if s.attributes['code'] == 'broken'

          check_maintenance_release(pkg, repo, firstarch)

          found_patchinfo = true
        end

      end

      # re-route (for the kgraft case building against GM or former incident)
      if is_maintenance_release? && tprj
        tprj = tprj.update_instance
        if tprj.is_maintenance_incident?
          release_target = nil
          pkg.project.repositories.includes(:release_targets).each do |repo|
            repo.release_targets.each do |rt|
              next if rt.trigger != 'maintenance'
              next unless rt.target_repository.project.is_maintenance_release?
              if release_target && release_target != rt.target_repository.project
                raise InvalidReleaseTarget, 'Multiple release target projects are not supported'
              end
              release_target = rt.target_repository.project
            end
          end
          raise InvalidReleaseTarget, 'Can not release to a maintenance incident project' unless release_target
          tprj = release_target
        end
      end

      # Will this be a new package ?
      unless missing_ok_link
        # check if the main package container exists in target.
        # take into account that an additional local link with spec file might got added
        unless e && tprj && tprj.exists_package?(ltpkg, follow_project_links: true, allow_remote_packages: false)
          if is_maintenance_release?
            pkg.project.repositories.includes(:release_targets).each do |repo|
              repo.release_targets.each do |rt|
                new_targets << rt.target_repository.project.name
              end
            end
            new_packages << pkg
            next
          elsif !is_maintenance_incident? && !is_submit?
            raise UnknownTargetPackage, 'target package does not exist'
          end
        end
      end
      new_action = dup
      new_action.source_package = pkg.name
      if is_maintenance_incident?
        new_targets << tprj.name if tprj
        new_action.target_releaseproject = releaseproject.name if releaseproject
      elsif !pkg.is_channel?
        new_targets << tprj.name
        new_action.target_project = tprj.name
        new_action.target_package = tpkg + incident_suffix
      end
      new_action.source_rev = rev if rev
      if is_maintenance_release?
        if pkg.is_channel?
          # create submit request for possible changes in the _channel file
          sumbit_action = BsRequestActionSubmit.new
          sumbit_action.source_project = new_action.source_project
          sumbit_action.source_package = new_action.source_package
          sumbit_action.source_rev = new_action.source_rev
          sumbit_action.target_project = tprj.name
          sumbit_action.target_package = tpkg
          # replace the new action
          new_action.destroy
          new_action = sumbit_action
        else # non-channel package
          next if ReleaseTarget.where(repository: pkg.project.repositories, target_repository: tprj.repositories, trigger: 'maintenance').empty?
          unless pkg.project.can_be_released_to_project?(tprj)
            raise WrongLinkedPackageSource, 'According to the source link of package ' \
                                            "#{pkg.project.name}/#{pkg.name} it would go to project" \
                                            "#{tprj.name} which is not specified as release target."
          end
        end
      end
      # no action, nothing to do
      next unless new_action
      # check if the source contains really a diff or we can skip the entire action
      if new_action.action_type.in?([:submit, :maintenance_incident]) && !new_action.contains_change?
        # submit contains no diff, drop it again
        new_action.destroy
      else
        newactions << new_action
      end
    end
    if is_maintenance_release? && !found_patchinfo && !opts[:ignore_build_state]
      raise MissingPatchinfo, 'maintenance release request without patchinfo would release no binaries'
    end

    # new packages (eg patchinfos) go to all target projects by default in maintenance requests
    new_targets.uniq!
    new_packages.uniq!
    new_packages.each do |pkg|
      release_targets = nil
      if pkg.is_patchinfo?
        release_targets = Patchinfo.new.fetch_release_targets(pkg)
      end
      new_targets.each do |p|
        if release_targets.present?
          found = false
          release_targets.each do |rt|
            if rt['project'] == p
              found = true
              break
            end
          end
          next unless found
        end

        # rubocop:disable Metrics/LineLength
        # skip if there is no active maintenance trigger for this package
        next if is_maintenance_release? && ReleaseTarget.where(repository: pkg.project.repositories, target_repository: Project.find_by_name(p).repositories, trigger: 'maintenance').empty?
        # rubocop:enable Metrics/LineLength

        new_action = dup
        new_action.source_package = pkg.name
        unless is_maintenance_incident?
          new_action.target_project = p
          new_action.target_package = pkg.name + incident_suffix
        end
        newactions << new_action
      end
    end

    newactions
  end
  # rubocop:enable Metrics/CyclomaticComplexity
  # rubocop:enable Metrics/PerceivedComplexity

  def check_action_permission_source!
    return unless source_project

    sprj = Project.get_by_name source_project
    raise UnknownProject, "Unknown source project #{source_project}" unless sprj
    unless sprj.class == Project || action_type.in?([:submit, :maintenance_incident])
      raise NotSupported, "Source project #{source_project} is not a local project. This is not supported yet."
    end

    if source_package
      spkg = Package.get_by_project_and_name(source_project, source_package, use_source: true, follow_project_links: true)
      spkg.check_weak_dependencies! if spkg && sourceupdate == 'cleanup'
    end

    check_permissions_for_sources!

    sprj
  end

  def check_action_permission!(skip_source = nil)
    # find objects if specified or report error
    role = nil
    sprj = nil
    if person_name
      # validate user object
      User.find_by_login!(person_name)
    end
    if group_name
      # validate group object
      Group.find_by_title!(group_name)
    end
    if self.role
      # validate role object
      role = Role.find_by_title!(self.role)
    end

    sprj = check_action_permission_source! unless skip_source
    tprj = check_action_permission_target!

    # Type specific checks
    if action_type == :delete || action_type == :add_role || action_type == :set_bugowner
      # check existence of target
      raise UnknownProject, 'No target project specified' unless tprj
      if action_type == :add_role
        raise UnknownRole, 'No role specified' unless role
      end
    elsif action_type.in?([:submit, :change_devel, :maintenance_release, :maintenance_incident])
      # check existence of source
      unless sprj || skip_source
        # no support for remote projects yet, it needs special support during accept as well
        raise UnknownProject, 'No target project specified'
      end

      if is_maintenance_incident?
        if target_package
          raise IllegalRequest, 'Maintenance requests accept only projects as target'
        end
        raise 'We should have expanded a target_project' unless target_project
        # validate project type
        prj = Project.get_by_name(target_project)
        unless prj.kind.in?(['maintenance', 'maintenance_incident'])
          raise IncidentHasNoMaintenanceProject, 'incident projects shall only create below maintenance projects'
        end
      end

      # source update checks
      if action_type.in?([:submit, :maintenance_incident])
        # cleanup implicit home branches. FIXME3.0: remove this, the clients should do this automatically meanwhile
        if sourceupdate.nil? && target_project
          if User.current.branch_project_name(target_project) == source_project
            self.sourceupdate = 'cleanup'
          end
        end
      end
      if action_type == :submit && tprj.is_a?(Project)
        at = AttribType.find_by_namespace_and_name!('OBS', 'MakeOriginOlder')
        self.makeoriginolder = true if tprj.attribs.find_by(attrib_type: at)
      end
      # allow cleanup only, if no devel package reference
      if sourceupdate == 'cleanup' && sprj.class != Project && !skip_source
        raise NotSupported, "Source project #{source_project} is not a local project. cleanup is not supported."
      end

      if action_type == :change_devel
        unless target_package
          raise UnknownPackage, 'No target package specified'
        end
      end
    end

    check_permissions!
  end

  def check_action_permission_target!
    return unless target_project

    tprj = Project.get_by_name target_project
    if tprj.is_a? Project
      if tprj.is_maintenance_release? && action_type == :submit
        raise SubmitRequestRejected, "The target project #{target_project} is a maintenance release project, " \
                                     'a submit self is not possible, please use the maintenance workflow instead.'
      end
      a = tprj.find_attribute('OBS', 'RejectRequests')
      if a && a.values.first
        if a.values.length < 2 || a.values.find_by_value(action_type)
          raise RequestRejected, "The target project #{target_project} is not accepting requests because: #{a.values.first.value}"
        end
      end
    end
    if target_package
      if Package.exists_by_project_and_name(target_project, target_package) ||
         action_type.in?([:delete, :change_devel, :add_role, :set_bugowner])
        tpkg = Package.get_by_project_and_name target_project, target_package
      end
      a = tpkg.find_attribute('OBS', 'RejectRequests') if defined?(tpkg) && tpkg
      if defined?(a) && a && a.values.first
        if a.values.length < 2 || a.values.find_by_value(action_type)
          raise RequestRejected, "The target package #{target_project} / #{target_package} is not accepting " \
                                 "requests because: #{a.values.first.value}"
        end
      end
    end

    tprj
  end

  def check_permissions!
    # to be overloaded in action classes if needed
  end

  def expand_targets(ignore_build_state)
    # expand target_package

    if action_type.in?([:submit, :maintenance_incident])
      if target_package &&
         Package.exists_by_project_and_name(target_project, target_package, follow_project_links: false)
        raise MissingAction unless contains_change?
        return
      end
    end

    # complete in formation available already?
    return if action_type == :submit && target_package
    return if action_type == :maintenance_release && target_package
    if action_type == :maintenance_incident && target_releaseproject && source_package
      pkg = Package.get_by_project_and_name(source_project, source_package)
      prj = Project.get_by_name(target_releaseproject).update_instance
      self.target_releaseproject = prj.name
      get_releaseproject(pkg, prj) if pkg
      return
    end

    if action_type.in?([:submit, :maintenance_release, :maintenance_incident])
      packages = []
      per_package_locking = false
      if source_package
        packages << Package.get_by_project_and_name(source_project, source_package)
        per_package_locking = true
      else
        packages = Project.get_by_name(source_project).packages
        per_package_locking = true if action_type == :maintenance_release
      end

      return create_expand_package(packages, ignore_build_state: ignore_build_state),
             per_package_locking
    end

    return
  end

  def source_access_check!
    sp = Package.find_by_project_and_name(source_project, source_package)
    if sp.nil?
      # either not there or read permission problem
      if Package.exists_on_backend?(source_package, source_project)
        # user is not allowed to read the source, but when he can write
        # the target, the request creator (who must have permissions to read source)
        # wanted the target owner to review it
        tprj = Project.find_by_name(target_project)
        if tprj.nil? || !User.current.can_modify_project?(tprj)
          # produce an error for the source
          Package.get_by_project_and_name(source_project, source_package)
        end
        return
      end
      if Project.exists_by_name(source_project)
        # it is a remote project
        return
      end
      # produce the same exception for webui
      Package.get_by_project_and_name(source_project, source_package)
    end
    if sp.class == String
      # a remote package
      return
    end
    sp.check_source_access!
  end

  def check_for_expand_errors!(add_revision)
    return unless action_type.in?([:submit, :maintenance_incident, :maintenance_release])

    # validate that the sources are not broken
    begin
      query = {}
      query[:expand] = 1 unless updatelink
      query[:rev] = source_rev if source_rev
      dir = Xmlhash.parse(Backend::Api::Sources::Package.files(source_project, source_package, query))
      if add_revision && !source_rev
        if action_type == :maintenance_release && dir['entry']
          # patchinfos in release requests get not frozen to allow to modify meta data
          return if dir['entry'].is_a?(Array) && dir['entry'].map { |e| e['name'] }.include?('_patchinfo')
          return if dir['entry'].is_a?(Hash) && dir['entry']['name'] == '_patchinfo'
        end
        self.source_rev = dir['srcmd5']
      end
    rescue ActiveXML::Transport::Error
      raise ExpandError, "The source of package #{source_project}/#{source_package}#{source_rev ? " for revision #{source_rev}" : ''} is broken"
    end
  end

  def set_target_associations
    self.target_package_object = Package.find_by_project_and_name(target_project, target_package)
    self.target_project_object = Project.find_by_name(target_project)
  end

  private

  def check_permissions_for_sources!
    return unless sourceupdate.in?(['update', 'cleanup']) || updatelink

    source_object = Package.find_by_project_and_name(source_project, source_package) ||
                    Project.get_by_name(source_project)

    raise LackingMaintainership if !source_object.is_a?(String) && !User.current.can_modify?(source_object)
  end
  #### Alias of methods
end

# == Schema Information
#
# Table name: bs_request_actions
#
#  id                    :integer          not null, primary key
#  bs_request_id         :integer          indexed, indexed => [target_package_id], indexed => [target_project_id]
#  type                  :string(255)
#  target_project        :string(255)      indexed
#  target_package        :string(255)      indexed
#  target_releaseproject :string(255)
#  source_project        :string(255)      indexed
#  source_package        :string(255)      indexed
#  source_rev            :string(255)
#  sourceupdate          :string(255)
#  updatelink            :boolean          default(FALSE)
#  person_name           :string(255)
#  group_name            :string(255)
#  role                  :string(255)
#  created_at            :datetime
#  target_repository     :string(255)
#  makeoriginolder       :boolean          default(FALSE)
#  target_package_id     :integer          indexed => [bs_request_id], indexed
#  target_project_id     :integer          indexed => [bs_request_id], indexed
#
# Indexes
#
#  bs_request_id                                                    (bs_request_id)
#  index_bs_request_actions_on_bs_request_id_and_target_package_id  (bs_request_id,target_package_id)
#  index_bs_request_actions_on_bs_request_id_and_target_project_id  (bs_request_id,target_project_id)
#  index_bs_request_actions_on_source_package                       (source_package)
#  index_bs_request_actions_on_source_project                       (source_project)
#  index_bs_request_actions_on_target_package                       (target_package)
#  index_bs_request_actions_on_target_package_id                    (target_package_id)
#  index_bs_request_actions_on_target_project                       (target_project)
#  index_bs_request_actions_on_target_project_id                    (target_project_id)
#
# Foreign Keys
#
#  bs_request_actions_ibfk_1  (bs_request_id => bs_requests.id)
#
