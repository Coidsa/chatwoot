<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMessageFormatter } from 'shared/composables/useMessageFormatter';
import { getInboxIconByType } from 'dashboard/helper/inbox';

import CardLayout from 'dashboard/components-next/CardLayout.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import LiveChatCampaignDetails from './LiveChatCampaignDetails.vue';
import SMSCampaignDetails from './SMSCampaignDetails.vue';

const props = defineProps({
  title: {
    type: String,
    default: '',
  },
  message: {
    type: String,
    default: '',
  },
  isLiveChatType: {
    type: Boolean,
    default: false,
  },
  isEnabled: {
    type: Boolean,
    default: false,
  },
  status: {
    type: String,
    default: '',
  },
  sender: {
    type: Object,
    default: null,
  },
  inbox: {
    type: Object,
    default: null,
  },
  scheduledAt: {
    type: Number,
    default: 0,
  },
  statistics: {
    type: Object,
    default: () => ({}),
  },
});

const emit = defineEmits(['edit', 'delete']);

const { t } = useI18n();

const STATUS_COMPLETED = 'completed';

const { formatMessage } = useMessageFormatter();

const isActive = computed(() =>
  props.isLiveChatType ? props.isEnabled : props.status !== STATUS_COMPLETED
);

const statusTextColor = computed(() => ({
  'text-n-teal-11': isActive.value,
  'text-n-slate-12': !isActive.value,
}));

const campaignStatus = computed(() => {
  if (props.isLiveChatType) {
    return props.isEnabled
      ? t('CAMPAIGN.LIVE_CHAT.CARD.STATUS.ENABLED')
      : t('CAMPAIGN.LIVE_CHAT.CARD.STATUS.DISABLED');
  }

  return props.status === STATUS_COMPLETED
    ? t('CAMPAIGN.SMS.CARD.STATUS.COMPLETED')
    : t('CAMPAIGN.SMS.CARD.STATUS.SCHEDULED');
});

const inboxName = computed(() => props.inbox?.name || '');

const inboxIcon = computed(() => {
  const { medium, channel_type: type } = props.inbox;
  return getInboxIconByType(type, medium);
});

const hasStatistics = computed(() => {
  if (!props.statistics || Object.keys(props.statistics).length === 0) {
    return false;
  }
  // Show statistics if there's any meaningful data (sent, delivered, read, failed, or total)
  return (
    (props.statistics.total && props.statistics.total > 0) ||
    (props.statistics.sent && props.statistics.sent > 0) ||
    (props.statistics.delivered && props.statistics.delivered > 0) ||
    (props.statistics.read && props.statistics.read > 0) ||
    (props.statistics.failed && props.statistics.failed > 0)
  );
});

const statisticsText = computed(() => {
  if (!hasStatistics.value) return '';
  const {
    total = 0,
    sent = 0,
    delivered = 0,
    read = 0,
    failed = 0,
    skipped_no_phone = 0,
    skipped_invalid_phone = 0,
    skipped_no_template = 0,
    skipped_duplicate_campaign = 0,
    skipped_race_condition = 0,
    error_summary = {},
  } = props.statistics;
  
  // Calculate total skipped
  const totalSkipped =
    skipped_no_phone +
    skipped_invalid_phone +
    skipped_no_template +
    skipped_duplicate_campaign +
    skipped_race_condition;
  
  const parts = [];
  
  // Success metrics
  if (sent > 0) parts.push(`${sent} sent`);
  if (delivered > 0) parts.push(`${delivered} delivered`);
  if (read > 0) parts.push(`${read} read`);
  
  // Failure metrics with error summary
  if (failed > 0) {
    const errorDetails = [];
    if (error_summary && Object.keys(error_summary).length > 0) {
      Object.entries(error_summary).forEach(([category, count]) => {
        const categoryName = category.replace(/_/g, ' ').toLowerCase();
        errorDetails.push(`${count} ${categoryName}`);
      });
      if (errorDetails.length > 0) {
        parts.push(`${failed} failed (${errorDetails.join(', ')})`);
      } else {
        parts.push(`${failed} failed`);
      }
    } else {
      parts.push(`${failed} failed`);
    }
  }
  
  // Skipped metrics (show total if > 0, or break down if details available)
  if (totalSkipped > 0) {
    const skippedDetails = [];
    if (skipped_no_phone > 0) skippedDetails.push(`${skipped_no_phone} no phone`);
    if (skipped_invalid_phone > 0) skippedDetails.push(`${skipped_invalid_phone} invalid phone`);
    if (skipped_no_template > 0) skippedDetails.push(`${skipped_no_template} no template`);
    if (skipped_duplicate_campaign > 0) skippedDetails.push(`${skipped_duplicate_campaign} duplicate`);
    if (skipped_race_condition > 0) skippedDetails.push(`${skipped_race_condition} race condition`);
    
    if (skippedDetails.length > 0) {
      parts.push(`skipped: ${skippedDetails.join(', ')}`);
    } else {
      parts.push(`${totalSkipped} skipped`);
    }
  }
  
  return parts.join(', ');
});
</script>

<template>
  <CardLayout layout="row">
    <div class="flex flex-col items-start justify-between flex-1 min-w-0 gap-2">
      <div class="flex justify-between gap-3 w-fit">
        <span
          class="text-base font-medium capitalize text-n-slate-12 line-clamp-1"
        >
          {{ title }}
        </span>
        <span
          class="text-xs font-medium inline-flex items-center h-6 px-2 py-0.5 rounded-md bg-n-alpha-2"
          :class="statusTextColor"
        >
          {{ campaignStatus }}
        </span>
      </div>
      <div
        v-dompurify-html="formatMessage(message, false, false, false)"
        class="text-sm text-n-slate-11 line-clamp-1 [&>p]:mb-0 h-6"
      />
      <div class="flex items-center w-full h-6 gap-2 overflow-hidden">
        <LiveChatCampaignDetails
          v-if="isLiveChatType"
          :sender="sender"
          :inbox-name="inboxName"
          :inbox-icon="inboxIcon"
        />
        <SMSCampaignDetails
          v-else
          :inbox-name="inboxName"
          :inbox-icon="inboxIcon"
          :scheduled-at="scheduledAt"
        />
      </div>
      <div
        v-if="hasStatistics && status === STATUS_COMPLETED"
        class="flex flex-col gap-1 text-xs text-n-slate-11"
      >
        <div class="flex items-center gap-2">
          <span class="font-medium">Statistics:</span>
        </div>
        <div class="text-n-slate-10 leading-relaxed">{{ statisticsText }}</div>
      </div>
    </div>
    <div class="flex items-center justify-end w-20 gap-2">
      <Button
        v-if="isLiveChatType"
        variant="faded"
        size="sm"
        color="slate"
        icon="i-lucide-sliders-vertical"
        @click="emit('edit')"
      />
      <Button
        variant="faded"
        color="ruby"
        size="sm"
        icon="i-lucide-trash"
        @click="emit('delete')"
      />
    </div>
  </CardLayout>
</template>
