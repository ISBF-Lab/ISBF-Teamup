# frozen_string_literal: true

module IsbfTeamup
  HOME_FIELD = "isbf_teamup_home"
  ANONYMOUS_FIELD = "isbf_per_post_anonymous"

  def self.category_id
    id = SiteSetting.isbf_teamup_category_id.to_i
    id if id.positive?
  end

  def self.enabled?
    SiteSetting.isbf_teamup_enabled && category_id
  end

  def self.teamup?(topic)
    enabled? && topic&.category_id == category_id && !topic.private_message?
  end

  def self.target?(options)
    return false unless enabled?
    if options[:topic_id].present?
      teamup?(Topic.find_by(id: options[:topic_id]))
    else
      options[:category].to_i == category_id && options[:archetype] != Archetype.private_message
    end
  end

  def self.home_supplied?(options)
    !options[HOME_FIELD.to_sym].nil?
  end

  def self.home_flag(value)
    return false if value.nil? || value == false || value == "false"
    return true if value == true || value == "true"
    raise Discourse::InvalidParameters.new(HOME_FIELD)
  end

  def self.show_on_home?(topic)
    !topic.custom_fields.key?(HOME_FIELD) || topic.custom_fields[HOME_FIELD] == true
  end

  def self.anonymous_identity?(user)
    user && (user.anonymous? || AnonymousUser.exists?(user_id: user.id))
  end

  def self.reject_anonymous!(user, options)
    requested = ActiveModel::Type::Boolean.new.cast(options[:isbf_anonymous])
    marked = options[:custom_fields]&.with_indifferent_access&.[](ANONYMOUS_FIELD)
    if requested || ActiveModel::Type::Boolean.new.cast(marked) || anonymous_identity?(user)
      raise Discourse::InvalidParameters.new(I18n.t("isbf_teamup.anonymous_not_allowed"))
    end
  end

  def self.validate_content!(title, raw)
    if title.to_s.strip.blank? || title.to_s.include?("[isbf-untitled:") || raw.to_s.strip.blank?
      raise Discourse::InvalidParameters.new(I18n.t("isbf_teamup.invalid"))
    end
  end

  def self.validate_creation!(user, options, guardian: Guardian.new(user))
    return unless SiteSetting.isbf_teamup_enabled
    targeted = target?(options)
    raise Discourse::InvalidParameters.new(HOME_FIELD) if home_supplied?(options) && !targeted
    return unless targeted

    raise Discourse::InvalidAccess unless user
    reject_anonymous!(user, options)
    if options[:topic_id].present?
      raise Discourse::InvalidParameters.new(HOME_FIELD) if home_supplied?(options)
      topic = Topic.find_by(id: options[:topic_id])
      raise Discourse::InvalidAccess unless guardian.can_create?(Post, topic)
      nil
    else
      category = Category.find_by(id: category_id)
      unless SiteSetting.isbf_teamup_publishing_enabled && category && guardian.can_create?(Topic, category)
        raise Discourse::InvalidAccess
      end
      validate_content!(options[:title], options[:raw])
      home_flag(options[HOME_FIELD.to_sym])
    end
  end

  def self.validate_post_author!(post)
    return unless teamup?(post.topic)
    reject_anonymous!(post.user, custom_fields: post.custom_fields)
  end

  def self.anonymous_content?(topic)
    posts = topic.posts
    marked = PostCustomField.where(name: ANONYMOUS_FIELD, value: "t").select(:post_id)
    shadows = AnonymousUser.select(:user_id)
    anonymous = posts.where(user_id: shadows).or(posts.where(id: marked))
    if defined?(IsbfAnonymous) && IsbfAnonymous.respond_to?(:pool_user_ids)
      anonymous = anonymous.or(posts.where(user_id: IsbfAnonymous.pool_user_ids))
    end
    anonymous.exists?
  end

  def self.validate_update!(editor, post, fields)
    return unless SiteSetting.isbf_teamup_enabled
    target_category = fields[:category_id].nil? ? post.topic.category_id : fields[:category_id].to_i
    targeted = teamup?(post.topic) || (post.is_first_post? && target_category == category_id)
    if home_supplied?(fields) && (!targeted || !post.is_first_post? || target_category != category_id)
      raise Discourse::InvalidParameters.new(HOME_FIELD)
    end
    return unless targeted

    raise Discourse::InvalidAccess unless Guardian.new(editor).can_edit_post?(post)
    reject_anonymous!(editor, fields)
    author = fields[:user_id].nil? ? post.user : User.find_by(id: fields[:user_id])
    reject_anonymous!(author, custom_fields: post.custom_fields)
    if post.is_first_post? && target_category == category_id
      if !teamup?(post.topic) && anonymous_content?(post.topic)
        raise Discourse::InvalidParameters.new(I18n.t("isbf_teamup.anonymous_not_allowed"))
      end
      validate_content!(fields.fetch(:title, post.topic.title), fields.fetch(:raw, post.raw))
      home_flag(fields[HOME_FIELD]) if home_supplied?(fields)
    end
  end

  def self.metadata(topic)
    { show_on_home: show_on_home?(topic) } if teamup?(topic)
  end

  def self.home_scope(topics)
    return topics unless enabled?
    topics.where(<<~SQL, category_id, HOME_FIELD)
      topics.category_id <> ? OR NOT EXISTS (
        SELECT 1 FROM topic_custom_fields AS teamup_home
        WHERE teamup_home.topic_id = topics.id AND teamup_home.name = ?
          AND teamup_home.value = 'f'
      )
    SQL
  end

  def self.filter(topics, values, guardian)
    return topics.none unless enabled? && guardian.user && values == ["all"]
    category = Category.find_by(id: category_id)
    return topics.none unless category && guardian.can_see_category?(category)

    topics.where(category_id: category_id, visible: true, deleted_at: nil).where(<<~SQL)
      EXISTS (SELECT 1 FROM posts AS teamup_post
        WHERE teamup_post.topic_id = topics.id AND teamup_post.post_number = 1
          AND teamup_post.deleted_at IS NULL AND NOT teamup_post.user_deleted
          AND NOT teamup_post.hidden)
    SQL
  end

  module PostCreation
    def valid?
      IsbfTeamup.validate_creation!(@user, opts, guardian: guardian)
      super
    end

    private

    # Native approval skips normal validation events, so check at persistence too.
    def save_post
      IsbfTeamup.validate_post_author!(@post)
      super
    end
  end

  module PostRevision
    def revise!(editor, fields, opts = {}, &block)
      fields = fields.with_indifferent_access
      fields.delete(HOME_FIELD) if fields[HOME_FIELD].nil?
      fields.delete(:isbf_anonymous) if fields[:isbf_anonymous].nil?
      IsbfTeamup.validate_update!(editor, @post, fields)
      super(editor, fields, opts, &block)
    end
  end

  module HomeQueryOptions
    def build_topic_list_options
      result = super
      result[:isbf_teamup_home_feed] = true if action_name == "latest"
      result
    end
  end
end