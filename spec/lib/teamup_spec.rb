# frozen_string_literal: true

require "rails_helper"

RSpec.describe IsbfTeamup do
  fab!(:category)
  fab!(:other_category) { Fabricate(:category) }
  fab!(:member) { Fabricate(:user, active: true, approved: true, trust_level: 1, refresh_auto_groups: true) }

  before do
    SiteSetting.isbf_teamup_enabled = true
    SiteSetting.isbf_teamup_publishing_enabled = true
    SiteSetting.isbf_teamup_category_id = category.id
    category.set_permissions(trust_level_0: :full, staff: :full)
    category.save!
  end

  def payload(extra = {})
    { category: category.id, title: "Looking for campus project teammates", raw: "Join our campus project team this semester." }.merge(extra)
  end

  describe ".home_flag" do
    [nil, false, "false"].each do |value|
      it("normalizes #{value.inspect} to false") { expect(described_class.home_flag(value)).to eq(false) }
    end
    [true, "true"].each do |value|
      it("normalizes #{value.inspect} to true") { expect(described_class.home_flag(value)).to eq(true) }
    end
    [0, 1, "yes", "0", "1", [], {}].each do |value|
      it "rejects #{value.inspect}" do
        expect { described_class.home_flag(value) }.to raise_error(Discourse::InvalidParameters)
      end
    end
  end

  it "keeps legacy home visibility and reports explicit opt-ins and opt-outs" do
    topic = Fabricate(:topic, category: category)
    expect(described_class.metadata(topic)).to eq(show_on_home: true)
    topic.custom_fields[described_class::HOME_FIELD] = false
    expect(described_class.metadata(topic)).to eq(show_on_home: false)
    topic.custom_fields[described_class::HOME_FIELD] = true
    expect(described_class.metadata(topic)).to eq(show_on_home: true)
    expect(described_class.metadata(Fabricate(:topic, category: other_category))).to be_nil
  end

  it "serializes missing and explicit flags through native preloaded custom fields" do
    topics = [nil, false, true].map do |home|
      topic = Fabricate(:topic, category: category)
      unless home.nil?
        topic.custom_fields[described_class::HOME_FIELD] = home
        topic.save_custom_fields
      end
      topic
    end
    Topic.preload_custom_fields(topics, [described_class::HOME_FIELD])
    expect(topics.map { |topic| described_class.metadata(topic) }).to eq(
      [{ show_on_home: true }, { show_on_home: false }, { show_on_home: true }],
    )
  end

  [{ title: "" }, { title: "  " }, { title: "[isbf-untitled:abc]" }, { raw: "" }, { raw: "  " }].each do |extra|
    it "requires real title and body even for direct creation with skipped native validation: #{extra.inspect}" do
      expect do
        expect do
          PostCreator.new(member, payload(extra).merge(skip_validations: true, skip_guardian: true, skip_events: true)).create
        end.to raise_error(Discourse::InvalidParameters)
      end.not_to change(Topic, :count)
    end
  end

  it "enforces native category creation rights even if the caller requests skip_guardian" do
    category.set_permissions(trust_level_0: :readonly, staff: :full)
    category.save!
    expect do
      PostCreator.new(member, payload(skip_validations: true, skip_guardian: true)).create
    end.to raise_error(Discourse::InvalidAccess)
  end

  it "rejects anonymous flags and private per-post markers for direct first posts and replies" do
    first = Fabricate(:post, topic: Fabricate(:topic, category: category))
    [{ isbf_anonymous: true }, { isbf_anonymous: "true" },
     { custom_fields: { described_class::ANONYMOUS_FIELD => true } }].each do |extra|
      [payload(extra), { topic_id: first.topic_id, raw: "I would like to join this campus project team." }.merge(extra)].each do |options|
        expect do
          expect do
            PostCreator.new(member, options.merge(skip_validations: true, skip_guardian: true, skip_events: true)).create
          end.to raise_error(Discourse::InvalidParameters)
        end.not_to change(Post, :count)
      end
    end
  end

  it "recognizes native shadow identities even when anonymous mode is switched off" do
    shadow = Fabricate(:user, trust_level: 1)
    AnonymousUser.create!(user_id: shadow.id, master_user_id: member.id, active: true)
    SiteSetting.allow_anonymous_mode = false
    expect(described_class.anonymous_identity?(shadow)).to eq(true)
    first = Fabricate(:post, topic: Fabricate(:topic, category: category))
    [payload, { topic_id: first.topic_id, raw: "I would like to join this campus project team." }].each do |options|
      expect do
        expect { PostCreator.new(shadow, options.merge(skip_validations: true, skip_guardian: true)).create }.to raise_error(Discourse::InvalidParameters)
      end.not_to change(Post, :count)
    end
  end

  it "uses the installed anonymous pool identity predicate when the companion plugin is loaded" do
    skip "ISBF Anonymous is tested on the deployment integration environment" unless defined?(IsbfAnonymous::PoolAssignment)
    SiteSetting.allow_anonymous_mode = true
    author = IsbfAnonymous::PoolAssignment.author_for!(member)
    expect(described_class.anonymous_identity?(author)).to eq(true)
    expect do
      PostCreator.new(author, payload(skip_validations: true, skip_guardian: true)).create
    end.to raise_error(Discourse::InvalidParameters)
  end

  it "prevents direct revision from assigning anonymous ownership or emptying a group first post" do
    first = Fabricate(:post, user: member, topic: Fabricate(:topic, user: member, category: category))
    shadow = Fabricate(:user, trust_level: 1)
    AnonymousUser.create!(user_id: shadow.id, master_user_id: member.id, active: true)
    [{ user_id: shadow.id }, { isbf_anonymous: true }, { raw: "" }, { title: "[isbf-untitled:abc]" }].each do |fields|
      expect do
        PostRevisor.new(first).revise!(member, fields, skip_validations: true)
      end.to raise_error(Discourse::InvalidParameters)
    end
    expect(first.reload.user_id).to eq(member.id)
  end

  it "rejects category moves with anonymous first posts or replies without changing their data" do
    shadow = Fabricate(:user, trust_level: 1)
    AnonymousUser.create!(user_id: shadow.id, master_user_id: member.id, active: true)
    [:marked_first, :marked_reply, :shadow_reply].each do |state|
      topic = Fabricate(:topic, user: member, category: other_category)
      first = Fabricate(:post, user: member, topic: topic)
      if state == :marked_first
        PostCustomField.create!(post_id: first.id, name: described_class::ANONYMOUS_FIELD, value: "t")
      else
        reply = Fabricate(:post, user: state == :shadow_reply ? shadow : member, topic: topic)
        PostCustomField.create!(post_id: reply.id, name: described_class::ANONYMOUS_FIELD, value: "t") if state == :marked_reply
      end
      expect do
        expect do
          PostRevisor.new(first).revise!(member, category_id: category.id)
        end.to raise_error(Discourse::InvalidParameters)
      end.not_to change { topic.reload.category_id }
      expect(topic.posts.count).to eq(state == :marked_first ? 1 : 2)
    end
  end

  it "allows native category moves with named content and a first-post home choice" do
    topic = Fabricate(:topic, user: member, category: other_category)
    first = Fabricate(:post, user: member, topic: topic)
    expect(PostRevisor.new(first).revise!(member, category_id: category.id, described_class::HOME_FIELD.to_sym => false)).to eq(true)
    expect(topic.reload.category_id).to eq(category.id)
    expect(topic.custom_fields[described_class::HOME_FIELD]).to eq(false)
  end

  it "leaves all native lists unchanged when the integration is disabled" do
    topic = Fabricate(:post, topic: Fabricate(:topic, category: category)).topic
    topic.custom_fields[described_class::HOME_FIELD] = false
    topic.save_custom_fields
    SiteSetting.isbf_teamup_enabled = false
    expect(described_class.home_scope(Topic.all).pluck(:id)).to include(topic.id)
    expect(described_class.metadata(topic)).to be_nil
    expect(described_class.filter(Topic.all, ["all"], Guardian.new(member))).to be_empty
  end
end

RSpec.describe IsbfTeamupCategoryIdValidator do
  fab!(:category)

  it "accepts an unset value or an existing category and rejects missing or malformed IDs" do
    validator = described_class.new
    expect(validator.valid_value?(0)).to eq(true)
    expect(validator.valid_value?(category.id)).to eq(true)
    [-1, "invalid", "", nil, Category.maximum(:id).to_i + 1].each do |value|
      expect(validator.valid_value?(value)).to eq(false)
    end
  end

  %i[isbf_marketplace_category_id isbf_learning_category_id].each do |setting|
    it "rejects sharing a category with #{setting}" do
      SiteSetting.stubs(setting).returns(category.id)
      expect(described_class.new.valid_value?(category.id)).to eq(false)
    end
  end
end
