module Intouch
  module IssuePatch
    def self.included(base) # :nodoc:
      base.class_eval do
        unloadable if Rails.env.production?

        # noinspection RubyArgCount
        store :intouch_data, accessors: %w(last_notification)

        before_save :check_alarm
        after_create :send_new_message

        def self.alarms
          Issue.where(priority_id: IssuePriority.alarm_ids)
        end

        def self.working
          Issue.where(status_id: IssueStatus.working_ids)
        end

        def self.feedbacks
          Issue.where(status_id: IssueStatus.feedback_ids)
        end

        def last_assigner_id
          journals.where(user_id: project.assigner_ids).last.try :user_id
        end

        def assigners_updated_on
          assigners_updated_on = journals.where(user_id: project.assigner_ids).last.try :created_on
          updated_on unless assigners_updated_on.present?
        end

        def alarm?
          IssuePriority.alarm_ids.include? priority_id
        end

        def unassigned?
          assigned_to.nil?
        end

        def assigned_to_group?
          assigned_to.class == Group
        end

        def working?
          IssueStatus.working_ids.include? status_id
        end

        def feedback?
          IssueStatus.feedback_ids.include? status_id
        end

        def without_due_date?
          !due_date.present? and created_on < 1.day.ago
        end

        def notification_state
          %w(unassigned assigned_to_group overdue without_due_date working feedback).select { |s| send("#{s}?") }.try :first
        end

        def recipient_ids(protocol, state = notification_state)
          if project.send("active_#{protocol}_settings") && state && project.send("active_#{protocol}_settings")[state]
            project.send("active_#{protocol}_settings")[state].map do |key, value|
              case key
                when 'author'
                  author.id
                when 'assigned_to'
                  if assigned_to.class == Group
                    assigned_to.user_ids
                  else
                    assigned_to_id if project.assigner_ids.include?(assigned_to_id)
                  end
                when 'watchers'
                  watchers.pluck(:user_id)
                else
                  nil
              end
            end.flatten.uniq + [last_assigner_id]
          end
        end

        def live_recipient_ids(protocol)
          settings = project.send("active_#{protocol}_settings")
          if settings.present?
            recipients = settings.select { |k, v| %w(author assigned_to watchers user_groups).include? k }

            user_ids = []
            recipients.each_pair do |key, value|
              if value.try(:[], status_id.to_s).try(:include?, priority_id.to_s)
                case key
                  when 'author'
                    user_ids << author.id
                  when 'assigned_to'
                    if assigned_to.class == Group
                      user_ids += assigned_to.user_ids
                    else
                      user_ids << assigned_to_id if project.assigner_ids.include?(assigned_to_id)
                    end
                  when 'watchers'
                    user_ids += watchers.pluck(:user_id)
                  else
                    nil
                end
              end
            end
            user_ids.flatten.uniq + [last_assigner_id] - [updated_by.try(:id)] # Не отправляем сообщение тому, то обновил задачу
          else
            []
          end
        end

        def intouch_recipients(protocol, state = notification_state)
          User.where(id: recipient_ids(protocol, state))
        end

        def intouch_live_recipients(protocol)
          User.where(id: live_recipient_ids(protocol))
        end

        def performer
          if assigned_to.present?
            if assigned_to.class == Group
              "Назначена на группу: #{assigned_to.name}"
            else
              assigned_to.name
            end
          end
        end

        def inactive?
          interval = project.active_intouch_settings.
              try(:[], 'working').try(:[], 'priority_notification').
              try(:[], "#{priority_id}").try(:[], 'interval')
          interval.present? and updated_on < interval.to_i.hours.ago
        end

        def inactive_message
          hours = ((Time.now - updated_on) / 3600).round(1)
          "Бездействие #{hours} ч."
        end

        def updated_by
          journals.last.user if journals.present?
        end

        def updated_details
          journals.last.visible_details.map{|detail| detail.prop_key.to_s.gsub(/_id$/, '')}
        end

        def updated_details_text
          updated_details.map {|field| I18n.t(('field_' + field).to_sym)}.join(', ') if updated_details
        end

        def telegram_live_message
          message = <<TEXT
Приоритет: #{priority.try :name}
Статус: #{status.try :name}
Исполнитель: #{performer}
#{project.name}: #{subject}
#{Intouch.issue_url(id)}
TEXT
          message = "Обновлено: #{updated_details_text}\n#{message}" if updated_details.present?
          message = "Обновил: #{updated_by}\n#{message}" if updated_by.present?
          message
        end

        def telegram_message
          message = <<TEXT
Приоритет: #{priority.try :name}
Статус: #{status.try :name}
Исполнитель: #{performer}
#{project.name}: #{subject}
#{Intouch.issue_url(id)}
TEXT
          message = "#{inactive_message}\n#{message}" if inactive?
          message = "*** Установите дату выполнения *** \n#{message}" if without_due_date?
          message = "*** Возьмите в работу (просроченная задача) ***  \n#{message}" if overdue?
          message = "*** Назначьте исполнителя *** \n#{message}" if unassigned? or assigned_to_group?
          message
        end

        private

        def check_alarm
          if project.module_enabled?(:intouch) and project.active? and !closed?
            if alarm? or Intouch.work_time?
              if Intouch.active_protocols.include? 'telegram'

                if changed_attributes and (changed_attributes['priority_id'] or changed_attributes['status_id'])
                  IntouchSender.send_live_telegram_group_message(id, status_id, priority_id)
                end

                IntouchSender.send_live_telegram_message(id)
              end

              IntouchSender.send_live_email_message(id) if Intouch.active_protocols.include? 'email'
            end
          end
        end

        def send_new_message
          if project.module_enabled?(:intouch) and project.active? and !closed?

            if Intouch.active_protocols.include? 'telegram'
              IntouchSender.send_live_telegram_message(id)
              IntouchSender.send_live_telegram_group_message(id, status_id, priority_id)
            end

            IntouchSender.send_live_email_message(id) if Intouch.active_protocols.include? 'email'
          end
        end

      end
    end

  end
end
Issue.send(:include, Intouch::IssuePatch)
