# frozen_string_literal: true

module IsbfTeamup
  class Engine < ::Rails::Engine
    engine_name "isbf-teamup"
    isolate_namespace IsbfTeamup
  end

  class TopicsController < ::ApplicationController
    requires_login
    requires_plugin "isbf-teamup"
    skip_before_action :check_xhr, only: :page

    def page
      category = Category.find_by(id: IsbfTeamup.category_id)
      raise Discourse::NotFound unless category && guardian.can_see_category?(category)
      render html: "".html_safe, layout: "application"
    end
  end
end