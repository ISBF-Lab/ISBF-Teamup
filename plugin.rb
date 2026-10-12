# frozen_string_literal: true

# name: isbf-teamup
# about: Native team-up topics with opt-in home display and named posting.
# version: 0.1.0
# authors: ISBF Lab
# url: https://github.com/ISBF-Lab/ISBF-Teamup
# required_version: 3.4.0

require_relative "app/validators/isbf_teamup_category_id_validator"

enabled_site_setting :isbf_teamup_enabled

after_initialize do
  require_relative "lib/isbf_teamup"
  require_relative "lib/isbf_teamup/controllers"

  register_topic_custom_field_type(IsbfTeamup::HOME_FIELD, :boolean)
  add_preloaded_topic_list_custom_field(IsbfTeamup::HOME_FIELD)
  add_permitted_post_create_param(IsbfTeamup::HOME_FIELD.to_sym, :string)
  add_permitted_post_create_param(:isbf_anonymous, :string)
  allow_new_queued_post_payload_attribute(IsbfTeamup::HOME_FIELD.to_sym)
  add_permitted_post_update_param(IsbfTeamup::HOME_FIELD.to_sym) do |post, value|
    if !value.nil? && !post.is_first_post?
      raise Discourse::InvalidParameters.new(IsbfTeamup::HOME_FIELD)
    end
  end
  add_permitted_post_update_param(:isbf_anonymous) do |post, value|
    IsbfTeamup.reject_anonymous!(post.user, isbf_anonymous: value) if IsbfTeamup.teamup?(post.topic)
  end

  PostRevisor.track_topic_field(IsbfTeamup::HOME_FIELD.to_sym) do |changes, value|
    next if value.nil?
    raise Discourse::InvalidAccess unless IsbfTeamup.teamup?(changes.topic)
    home = IsbfTeamup.home_flag(value)
    changes.record_change(IsbfTeamup::HOME_FIELD, changes.topic.custom_fields[IsbfTeamup::HOME_FIELD], home)
    changes.topic.custom_fields[IsbfTeamup::HOME_FIELD] = home
  end

  %i[topic_view topic_list_item].each do |serializer|
    add_to_serializer(serializer, :isbf_teamup) do
      topic = object.respond_to?(:topic) ? object.topic : object
      IsbfTeamup.metadata(topic)
    end
  end
  add_to_serializer(:post, :isbf_teamup, include_condition: -> { object.is_first_post? }) do
    IsbfTeamup.metadata(object.topic)
  end
  add_to_serializer(:site, :isbf_teamup, include_condition: -> { IsbfTeamup.category_id && Category.exists?(id: IsbfTeamup.category_id) }) do
    {
      category_id: IsbfTeamup.category_id,
      enabled: SiteSetting.isbf_teamup_enabled,
      publishing_enabled: SiteSetting.isbf_teamup_publishing_enabled,
      version: 1,
    }
  end

  NewPostManager.add_handler(-100) do |manager|
    next unless SiteSetting.isbf_teamup_enabled
    next unless IsbfTeamup.target?(manager.args) || IsbfTeamup.home_supplied?(manager.args)
    begin
      home = IsbfTeamup.validate_creation!(manager.user, manager.args, guardian: Guardian.new(manager.args[:acting_user] || manager.user))
      # Native queue payload handling drops false booleans; strings retain either choice.
      manager.args[IsbfTeamup::HOME_FIELD.to_sym] = home.to_s if manager.args[:topic_id].blank?
      nil
    rescue Discourse::InvalidParameters, Discourse::InvalidAccess
      result = NewPostResult.new(:create_post, false)
      result.errors.add(:base, I18n.t("isbf_teamup.invalid"))
      result
    end
  end

  on(:before_create_topic) do |topic, creator|
    next unless IsbfTeamup.teamup?(topic)
    home = IsbfTeamup.validate_creation!(creator.user, creator.opts, guardian: creator.guardian)
    topic.custom_fields[IsbfTeamup::HOME_FIELD] = home
  end

  on(:before_edit_post) { |post, _fields| IsbfTeamup.validate_post_author!(post) }
  PostCreator.prepend(IsbfTeamup::PostCreation)
  PostRevisor.prepend(IsbfTeamup::PostRevision)

  ListController.prepend(IsbfTeamup::HomeQueryOptions)
  TopicQuery.add_custom_filter(:isbf_teamup_home_feed) do |topics, query|
    if query.options[:isbf_teamup_home_feed] && query.options[:category].blank? &&
         query.options[:tags].blank? && query.options[:q].blank?
      IsbfTeamup.home_scope(topics)
    else
      topics
    end
  end
  add_filter_custom_filter("isbf-teamup") { |scope, values, guardian| IsbfTeamup.filter(scope, values, guardian) }

  IsbfTeamup::Engine.routes.draw { get "/" => "topics#page" }
  Discourse::Application.routes.append { mount ::IsbfTeamup::Engine, at: "/isbf/teamup" }
end