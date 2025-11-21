class Campaigns::TriggerOneoffCampaignJob < ApplicationJob
  queue_as :low

  def perform(campaign)
    Rails.logger.info "=" * 80
    Rails.logger.info "🚀 Starting Campaign Trigger Job"
    Rails.logger.info "Campaign ID: #{campaign.id}"
    Rails.logger.info "Campaign Title: #{campaign.title}"
    Rails.logger.info "Campaign Type: #{campaign.campaign_type}"
    Rails.logger.info "Campaign Status: #{campaign.campaign_status}"
    Rails.logger.info "=" * 80
    
    campaign.trigger!
    
    Rails.logger.info "✅ Campaign Trigger Job completed for Campaign #{campaign.id}"
  rescue StandardError => e
    Rails.logger.error "❌ ERROR in Campaign Trigger Job for Campaign #{campaign.id}"
    Rails.logger.error "Error: #{e.class} - #{e.message}"
    Rails.logger.error "Backtrace: #{e.backtrace.first(10).join('\n')}"
    raise
  end
end
