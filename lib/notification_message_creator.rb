#
# Copyright (C) 2013 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

class NotificationMessageCreator
  include LocaleSelection

  attr_accessor :notification, :asset, :to_user_channels, :message_data

  # Options can include:
  #  :to_list - A list of Users, User IDs, and CommunicationChannels to send to
  #  :data - Options merged with Message options
  def initialize(notification, asset, options={})
    @notification = notification
    @asset = asset
    @to_user_channels = user_channels(options[:to_list])
    @user_counts = recent_messages_for_users(@to_user_channels.keys)
    @message_data = options.delete(:data)
    course_id = @message_data&.dig(:course_id)
    root_account_id = @message_data&.dig(:root_account_id)
    if course_id && root_account_id
      @account = Account.new(id: root_account_id)
      @course = Course.new(id: course_id)
      @mute_notifications_by_course_enabled = @account.feature_enabled?(:mute_notifications_by_course)
      @override_preferences_enabled = Account.site_admin.feature_enabled?(:notification_granular_course_preferences)
    end
  end

  # Public: create (and dispatch, and queue delayed) a message
  # for this notification, associated with the given asset, sent to the given recipients
  #
  # asset - what the message applies to. An assignment, a discussion, etc.
  # to_list - a list of who to send the message to. the list can contain Users, User ids, or CommunicationChannels
  # options - a hash of extra options to merge with the options used to build the Message
  #
  # Returns a list of the messages dispatched immediately
  def create_message
    dashboard_messages = []
    immediate_messages = []
    delayed_messages = []

    @to_user_channels.each do |user, channels|
      # asset_applied_to is used for the asset (ie assignment, announcement)
      # to filter users out that do not apply to the notification like when a due
      # date is different for a specific user when using variable due dates.
      next unless (asset = asset_applied_to(user))
      user_locale = infer_locale(user: user, context: user_asset_context(asset), ignore_browser_locale: true)
      I18n.with_locale(user_locale) do
        channels.each do |default_channel|
          if @notification.registration?
            immediate_messages += build_immediate_messages_for(user, [default_channel])
          elsif @notification.summarizable?
            policy = delayed_policy_for(user, default_channel)
            delayed_messages << build_summary_for(user, policy) if policy
          end
        end

        unless @notification.registration?
          if @notification.summarizable? && no_daily_messages_in(delayed_messages) && too_many_messages_for?(user)
            fallback = build_fallback_for(user)
            delayed_messages << fallback if fallback
          end

          unless user.pre_registered?
            immediate_messages += build_immediate_messages_for(user)
            dashboard_messages << build_dashboard_message_for(user) if @notification.dashboard? && @notification.show_in_feed?
          end
        end
      end
    end

    delayed_messages.each{ |message| message.save! }
    dispatch_dashboard_messages(dashboard_messages)
    dispatch_immediate_messages(immediate_messages)

    return immediate_messages + dashboard_messages
  end

  private

  def no_daily_messages_in(delayed_messages)
    !delayed_messages.any?{ |message| message.frequency == 'daily' }
  end

  # Notifications are enabled for a user in a course by default, but can be
  # disabled for notifications. The broadcast_policy needs to pass both the
  # course_id and the root_account_id to the set_broadcast_policy block for us
  # to be able to look up if it should be disabled. root_account_id is used
  # right now to look up the feature flag, but it can also be used to set
  # root_account_id on the message, or look up policy overrides in the future.
  # A user can disable notifications for a course with a notification policy
  # override.
  def notifications_enabled_for_context?(user, context)
    return true unless @notification.summarizable?
    if @mute_notifications_by_course_enabled
      return NotificationPolicyOverride.enabled_for(user, context)
    end
    true
  end

  def build_fallback_for(user)
    fallback_channel = immediate_channels_for(user).find{ |cc| cc.path_type == 'email'}
    return unless fallback_channel
    fallback_policy = nil
    NotificationPolicy.unique_constraint_retry do
      fallback_policy = fallback_channel.notification_policies.by_frequency('daily').where(:notification_id => nil).first
      fallback_policy ||= fallback_channel.notification_policies.create!(frequency: 'daily')
    end

    build_summary_for(user, fallback_policy)
  end

  def build_summary_for(user, policy)
    user.shard.activate do
      message = user.messages.build(message_options_for(user))
      message.parse!('summary')
      delayed_message = policy.delayed_messages.build(:notification => @notification,
                                    :frequency => policy.frequency,
                                    # policy.communication_channel should
                                    # already be loaded in memory as the
                                    # inverse association of loading the
                                    # policy from the channel. passing the
                                    # object through here lets the delayed
                                    # message use it without having to re-query.
                                    :communication_channel => policy.communication_channel,
                                    :root_account_id => message.context_root_account.try(:id),
                                    :name_of_topic => message.subject,
                                    :link => message.url,
                                    :summary => message.body)
      delayed_message.context = @asset
      delayed_message.save! if Rails.env.test?
      delayed_message
    end
  end

  def build_immediate_messages_for(user, channels=immediate_channels_for(user).reject(&:unconfirmed?))
    return [] unless notifications_enabled_for_context?(user, @course)

    messages = []
    message_options = message_options_for(user)
    channels.reject!{ |channel| ['email', 'sms'].include?(channel.path_type) } if @notification.summarizable? && too_many_messages_for?(user)
    channels.reject!(&:bouncing?)
    channels.each do |channel|
      messages << user.messages.build(message_options.merge(:communication_channel => channel,
                                                            :to => channel.path))
    end
    messages.each(&:parse!)
    messages
  end

  def dispatch_immediate_messages(messages)
    Message.transaction do
      # Cancel any that haven't been sent out for the same purpose
      cancel_pending_duplicate_messages
      messages.each do |message|
        message.stage_without_dispatch!
        message.save!
      end
    end
    MessageDispatcher.batch_dispatch(messages)

    messages
  end

  def build_dashboard_message_for(user)
    message = user.messages.build(message_options_for(user).merge(:to => 'dashboard'))
    message.parse!
    message
  end

  def dispatch_dashboard_messages(messages)
    messages.each do |message|
      message.infer_defaults
      message.create_stream_items
    end
    messages
  end

  def delayed_policy_for(user, channel, notification: @notification)
    return if !channel.active?
    return if too_many_messages_for?(user)
    return if channel.path_type != 'email'
    return unless notifications_enabled_for_context?(user, @course)

    if @override_preferences_enabled
      policy = override_policy_for(channel, @message_data&.dig(:course_id), 'Course')
      policy ||= override_policy_for(channel, @message_data&.dig(:root_account_id), 'Account')
    end
    if !policy && should_use_default_policy?(user, channel)
      policy ||= channel.notification_policies.new(notification_id: @notification.id, frequency: @notification.default_frequency(user))
    end
    # We use find here because the policies and policy overrides are already loaded and we don't want to execute a query
    policy ||= channel.notification_policies.find { |np| np.notification_id == notification.id }
    policy if ['daily', 'weekly'].include?(policy&.frequency)
  end

  def should_use_default_policy?(user, channel)
    # only use new policies for default channel when there are no other policies for the notification and user.
    # If another policy exists then it means the notification preferences page has been visited and null values
    # show as never policies in the UI.
    default_email?(user, channel) && (user.notification_policies.find { |np| np.notification_id == @notification.id }).nil?
  end

  def default_email?(user, channel)
    user.email_channel == channel
  end

  def override_policy_for(channel, context_id, context_type, notification: @notification)
    if context_id
      channel.notification_policy_overrides.find do |np|
        np.notification_id == notification.id &&
        np.context_id == context_id &&
        np.context_type == context_type
      end
    end
  end

  def user_channels(to_list)
    to_user_channels = Hash.new([])
    # if this method is given users we preload communication channels and they
    # are already loaded so we are using the select :active? to not do another
    # query to load them again.
    users_from_to_list(to_list).each do |user|
      to_user_channels[user] += user.communication_channels.select(&:active?)
    end
    # if the method gets communication channels, the user is loaded, and this
    # allows all the methods in this file to behave the same as if it were users.
    communication_channels_from_to_list(to_list).each do |channel|
      to_user_channels[channel.user] += [channel]
    end
    to_user_channels.each_value(&:uniq!)
    to_user_channels
  end

  def users_from_to_list(to_list)
    to_list = [to_list] unless to_list.is_a? Enumerable

    to_users = []
    to_users += User.find(to_list.select{ |to| to.is_a? Numeric }.uniq)
    to_users += to_list.select{ |to| to.is_a? User }
    to_users.uniq!

    to_users
  end

  def communication_channels_from_to_list(to_list)
    to_list = [to_list] unless to_list.is_a? Enumerable
    to_list.select{ |to| to.is_a? CommunicationChannel }.uniq
  end

  def asset_applied_to(user)
    if asset.respond_to?(:filter_asset_by_recipient)
      asset.filter_asset_by_recipient(@notification, user)
    else
      asset
    end
  end

  def message_options_for(user)
    user_asset = asset_applied_to(user)

    message_options = {
      :subject => @notification.subject,
      :notification => @notification,
      :notification_name => @notification.name,
      :user => user,
      :context => user_asset,
    }

    # can't just merge these because nil values need to be overwritten in a later merge
    message_options[:delay_for] = @notification.delay_for if @notification.delay_for
    message_options[:data] = @message_data if @message_data
    message_options
  end

  def user_asset_context(user_asset)
    if user_asset.is_a?(Context)
      user_asset
    elsif user_asset.respond_to?(:context)
      user_asset.context
    end
  end

  # Finds channels for a user that should get this notification immediately
  #
  # If the user doesn't have a policy for this notification on a non-push
  # channel and the default frequency is immediate, the user should get the
  # notification by email.
  # Unregistered users don't get notifications. (registration notifications
  # are a special case handled elsewhere)
  def immediate_channels_for(user)
    return [] unless user.registered?

    active_channel_scope = user.communication_channels.select do |cc|
      cc.active? &&
      (
        (@override_preferences_enabled && override_policy_for(cc, @message_data&.dig(:course_id), 'Course')) ||
        (@override_preferences_enabled && override_policy_for(cc, @message_data&.dig(:root_account_id), 'Account')) ||
        cc.notification_policies.find { |np| np.notification_id == @notification.id }
      )
    end
    immediate_channel_scope = active_channel_scope.select do |cc|
      if @override_preferences_enabled
        policy = override_policy_for(cc, @message_data&.dig(:course_id), 'Course')
        policy ||= override_policy_for(cc, message_data&.dig(:root_account_id), 'Account')
      end
      policy ||= cc.notification_policies.find { |np| np.notification_id == @notification.id }
      policy.frequency == 'immediately'
    end

    user_has_a_policy = active_channel_scope.find { |cc| cc.path_type != 'push' }
    if !user_has_a_policy && @notification.default_frequency(user) == 'immediately'
      return [user.email_channel, *immediate_channel_scope.select { |cc| cc.path_type == 'push' }].compact
    end
    immediate_channel_scope
  end

  def cancel_pending_duplicate_messages
    # doesn't include dashboard messages. should it?
    Message.where(:notification_id => @notification).
      for(@asset).
      by_name(@notification.name).
      for_user(@to_user_channels.keys).
      cancellable.
      where("created_at BETWEEN ? AND ?", Setting.get("pending_duplicate_message_window_hours", "6").to_i.hours.ago, Time.now.utc).
      update_all(:workflow_state => 'cancelled')
  end

  def too_many_messages_for?(user)
    @user_counts[user.id] >= user.max_messages_per_day
  end

  # Cache the count for number of messages sent to a user/user-with-category,
  # it can also be manually re-set to reflect new rows added... this cache
  # data can get out of sync if messages are cancelled for being repeats...
  # not sure if we care about that...
  def recent_messages_for_users(users)
    Shackles.activate(:slave) do
      Hash.new(0).merge(Message.more_recent_than(24.hours.ago).where(user_id: users, to_email: true).group(:user_id).count)
    end
  end
end
