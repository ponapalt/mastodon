# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SuspendAccountService do
  shared_examples 'common behavior' do
    subject { described_class.new.call(account) }

    let!(:local_follower) { Fabricate(:user, current_sign_in_at: 1.hour.ago).account }
    let!(:list)           { Fabricate(:list, account: local_follower) }

    before do
      allow(FeedManager.instance).to receive_messages(unmerge_from_home: nil, unmerge_from_list: nil)
      allow(Rails.configuration.x.cache_buster).to receive(:enabled).and_return(true)

      local_follower.follow!(account)
      list.accounts << account

      account.suspend!

      Fabricate(:media_attachment, file: attachment_fixture('boop.ogg'), account: account)
    end

    it 'unmerges from feeds of local followers and changes file mode and preserves suspended flag' do
      expect { subject }
        .to change_file_mode
        .and enqueue_sidekiq_job(CacheBusterWorker).with(account.media_attachments.first.file.url(:original))
        .and not_change_suspended_flag
      expect(FeedManager.instance).to have_received(:unmerge_from_home).with(account, local_follower)
      expect(FeedManager.instance).to have_received(:unmerge_from_list).with(account, list)
    end

    def change_file_mode
      change { File.stat(account.media_attachments.first.file.path).mode }
    end

    def not_change_suspended_flag
      not_change(account, :suspended?)
    end
  end

  describe 'suspending a local account' do
    def match_update_actor_request(json, account)
      json = JSON.parse(json)
      actor_id = ActivityPub::TagManager.instance.uri_for(account)
      json['type'] == 'Update' && json['actor'] == actor_id && json['object']['id'] == actor_id && json['object']['suspended']
    end

    it_behaves_like 'common behavior' do
      let!(:account)         { Fabricate(:account) }
      let!(:remote_follower) { Fabricate(:account, uri: 'https://alice.com', inbox_url: 'https://alice.com/inbox', protocol: :activitypub, domain: 'alice.com') }
      let!(:remote_reporter) { Fabricate(:account, uri: 'https://bob.com', inbox_url: 'https://bob.com/inbox', protocol: :activitypub, domain: 'bob.com') }

      before do
        Fabricate(:report, account: remote_reporter, target_account: account)
        remote_follower.follow!(account)
      end

      it 'sends an Update actor activity to followers and reporters' do
        subject

        expect(ActivityPub::DeliveryWorker)
          .to have_enqueued_sidekiq_job(satisfying { |json| match_update_actor_request(json, account) }, account.id, remote_follower.inbox_url).once
          .and have_enqueued_sidekiq_job(satisfying { |json| match_update_actor_request(json, account) }, account.id, remote_reporter.inbox_url).once
      end
    end
  end

  describe 'suspending a remote account' do
    def match_reject_follow_request(json, account, followee)
      json = JSON.parse(json)
      json['type'] == 'Reject' && json['actor'] == ActivityPub::TagManager.instance.uri_for(followee) && json['object']['actor'] == account.uri
    end

    it_behaves_like 'common behavior' do
      let!(:account)        { Fabricate(:account, domain: 'bob.com', uri: 'https://bob.com', inbox_url: 'https://bob.com/inbox', protocol: :activitypub) }
      let!(:local_followee) { Fabricate(:account) }

      before do
        account.follow!(local_followee)
      end

      it 'sends a Reject Follow activity', :aggregate_failures do
        subject

        expect(ActivityPub::DeliveryWorker)
          .to have_enqueued_sidekiq_job(satisfying { |json| match_reject_follow_request(json, account, local_followee) }, local_followee.id, account.inbox_url).once
      end
    end
  end
end
