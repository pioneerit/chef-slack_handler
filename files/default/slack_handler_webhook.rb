#
# Author:: Dell Cloud Manager OSS
# Copyright:: Dell, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "chef"
require "chef/handler"
require 'net/http'
require "timeout"

class Chef::Handler::Slack < Chef::Handler
  attr_reader :webhooks, :username, :config, :timeout, :icon_emoji, :fail_only, :message_detail_level, :cookbook_detail_level

  def initialize(config = {})
    Chef::Log.debug('Initializing Chef::Handler::Slack')
    @config = config
    @timeout = @config[:timeout]
    @icon_emoji = @config[:icon_emoji]
    @icon_url = @config[:icon_url]
    @username = @config[:username]
    @webhooks = @config[:webhooks]
    @fail_only = @config[:fail_only]
    @message_detail_level = @config[:message_detail_level]
    @cookbook_detail_level = @config[:cookbook_detail_level]
  end

  def report
    @webhooks['name'].each do |val|
      Chef::Log.debug("Sending handler report to webhook #{val}")
      webhook = node['chef_client']['handler']['slack']['webhooks'][val]
      Timeout.timeout(@timeout) do
        sending_to_slack = false
        sending_to_slack = true unless ( run_status.success? and fail_only(webhook) )
        if sending_to_slack
          Chef::Log.info("Sending report to Slack webhook #{webhook['url']}")  
          slack_message("#{message(webhook)}", attachment_message(webhook), webhook['url'])
        end
      end
    end
  rescue Exception => e
    Chef::Log.warn("Failed to send message to Slack: #{e.message}")
  end

  private

  def fail_only(webhook)
    return webhook['fail_only'] unless webhook['fail_only'].nil?
    @fail_only
  end

  def message(context)
    if run_status.success?
      return ":white_check_mark: #{Chef::Config[:chef_server_url]}"
    else
      ":sos: #{Chef::Config[:chef_server_url]}\n```#{run_status.backtrace}```"
    end
  end

  def run_status_message_detail(message_detail_level)
    message_detail_level ||= @message_detail_level
    case message_detail_level
    when "resources"
      "resources updated \n #{updated_resources.join(', ')}" unless updated_resources.nil?
    end
  end

  def attachment_message(context)
    [{
      fallback: "#{run_status_human_readable} on *_#{run_status.node.name}_*",
      color: run_status_color,
      author_name: 'chef_client',
      text: "#{run_status_cookbook_detail(context['cookbook_detail_level'])}",
      fields: [
        {
          title: 'Status',
          value: "#{run_status_human_readable}",
          short: true
        },
        {
          title: 'Node',
          value: "#{run_status.node.name}",
          short: true
        },
        {
          title: 'Elapsed',
          value: "#{run_status.elapsed_time}",
          short: true
        },
        {
          title: 'Updated',
          value: "#{updated_resources.count unless updated_resources.nil?}",
          short: true
        },
        ]
    },
    {
      text: "#{run_status_message_detail(context['message_detail_level'])}"
    },
    {
      text: "#{run_status.formatted_exception unless run_status.success?}"
    }
  ]
  end

  def slack_message(message, attachment, webhook)
    Chef::Log.debug("Sending slack message #{message} to webhook #{webhook} #{attachment ? 'with' : 'without'} a text attachment")
    uri = URI.parse(webhook)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    req = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
    req.body = request_body(message, attachment)
    http.request(req)
  end

  def request_body(message, attachment)
    body = {}
    body[:username] = @username unless @username.nil?
    body[:text] = message unless message.nil?
    # icon_url takes precedence over icon_emoji
    if @icon_url
      body[:icon_url] = @icon_url
    elsif @icon_emoji
      body[:icon_emoji] = @icon_emoji
    end
    body[:attachments] = attachment
    body.to_json
  end

  def run_status_human_readable
    run_status.success? ? "SUCCEEDED" : "FAILED"
  end

  def run_status_color
    run_status.success? ? "good" : "danger"
  end

  def run_status_cookbook_detail(cookbook_detail_level)
    cookbook_detail_level ||= @cookbook_detail_level
    case cookbook_detail_level
    when "all"
      cookbooks = Chef.run_context.cookbook_collection
      "cookbooks: #{cookbooks.values.map { |x| x.name.to_s + ' ' + x.version }}"
    end
  end
end
