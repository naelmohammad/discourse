require 'rails_helper'
require_dependency 'single_sign_on'

describe Admin::UsersController do

  it 'is a subclass of AdminController' do
    expect(Admin::UsersController < Admin::AdminController).to eq(true)
  end

  context 'while logged in as an admin' do
    before do
      @user = log_in(:admin)
    end

    context '.index' do
      it 'returns success' do
        get :index, format: :json
        expect(response).to be_success
      end

      it 'returns JSON' do
        get :index, format: :json
        expect(::JSON.parse(response.body)).to be_present
      end

      context 'when showing emails' do

        it "returns email for all the users" do
          get :index, params: { show_emails: "true" }, format: :json
          data = ::JSON.parse(response.body)
          data.each do |user|
            expect(user["email"]).to be_present
          end
        end

        it "logs only 1 enty" do
          expect(UserHistory.where(action: UserHistory.actions[:check_email], acting_user_id: @user.id).count).to eq(0)

          get :index, params: { show_emails: "true" }, format: :json

          expect(UserHistory.where(action: UserHistory.actions[:check_email], acting_user_id: @user.id).count).to eq(1)
        end

      end
    end

    describe '.show' do
      context 'an existing user' do
        it 'returns success' do
          get :show, params: { id: @user.id }, format: :json
          expect(response).to be_success
        end
      end

      context 'an existing user' do
        it 'returns success' do
          get :show, params: { id: 0 }, format: :json
          expect(response).not_to be_success
        end
      end
    end

    context '.approve_bulk' do

      let(:evil_trout) { Fabricate(:evil_trout) }

      it "does nothing without uesrs" do
        User.any_instance.expects(:approve).never
        put :approve_bulk, format: :json
      end

      it "won't approve the user when not allowed" do
        Guardian.any_instance.expects(:can_approve?).with(evil_trout).returns(false)
        User.any_instance.expects(:approve).never
        put :approve_bulk, params: { users: [evil_trout.id] }, format: :json
      end

      it "approves the user when permitted" do
        Guardian.any_instance.expects(:can_approve?).with(evil_trout).returns(true)
        User.any_instance.expects(:approve).once
        put :approve_bulk, params: { users: [evil_trout.id] }, format: :json
      end

    end

    context '.generate_api_key' do
      let(:evil_trout) { Fabricate(:evil_trout) }

      it 'calls generate_api_key' do
        User.any_instance.expects(:generate_api_key).with(@user)
        post :generate_api_key, params: { user_id: evil_trout.id }, format: :json
      end
    end

    context '.revoke_api_key' do

      let(:evil_trout) { Fabricate(:evil_trout) }

      it 'calls revoke_api_key' do
        User.any_instance.expects(:revoke_api_key)
        delete :revoke_api_key, params: { user_id: evil_trout.id }, format: :json
      end

    end

    context '.approve' do

      let(:evil_trout) { Fabricate(:evil_trout) }

      it "raises an error when the user doesn't have permission" do
        Guardian.any_instance.expects(:can_approve?).with(evil_trout).returns(false)
        put :approve, params: { user_id: evil_trout.id }, format: :json
        expect(response).to be_forbidden
      end

      it 'calls approve' do
        User.any_instance.expects(:approve).with(@user)
        put :approve, params: { user_id: evil_trout.id }, format: :json
      end

    end

    context '.suspend' do
      let(:user) { Fabricate(:evil_trout) }

      it "works properly" do
        Fabricate(:api_key, user: user)
        expect(user).not_to be_suspended
        put(
          :suspend,
          params: {
            user_id: user.id,
            suspend_until: 5.hours.from_now,
            reason: "because I said so",
            format: :json
          }
        )
        expect(response).to be_success

        user.reload
        expect(user).to be_suspended
        expect(user.suspended_at).to be_present
        expect(user.suspended_till).to be_present
        expect(ApiKey.where(user_id: user.id).count).to eq(0)

        log = UserHistory.where(target_user_id: user.id).order('id desc').first
        expect(log).to be_present
        expect(log.details).to match(/because I said so/)
      end

      it "can have an associated post" do
        post = Fabricate(:post)

        put(
          :suspend,
          params: {
            user_id: user.id,
            suspend_until: 5.hours.from_now,
            reason: "because of this post",
            post_id: post.id,
            format: :json
          }
        )
        expect(response).to be_success

        log = UserHistory.where(target_user_id: user.id).order('id desc').first
        expect(log).to be_present
        expect(log.post_id).to eq(post.id)
      end

      it "can send a message to the user" do
        Jobs.expects(:enqueue).with(
          :critical_user_email,
          has_entries(
            type: :account_suspended,
            user_id: user.id
          )
        )

        put(
          :suspend,
          params: {
            user_id: user.id,
            suspend_until: 10.days.from_now,
            reason: "short reason",
            message: "long reason",
            format: :json
          }
        )
        expect(response).to be_success

        log = UserHistory.where(target_user_id: user.id).order('id desc').first
        expect(log).to be_present
        expect(log.details).to match(/short reason/)
        expect(log.details).to match(/long reason/)
      end

      it "also revoke any api keys" do
        User.any_instance.expects(:revoke_api_key)
        put :suspend, params: { user_id: user.id }, format: :json
      end

    end

    context '.revoke_admin' do
      before do
        @another_admin = Fabricate(:admin)
      end

      it 'raises an error unless the user can revoke access' do
        Guardian.any_instance.expects(:can_revoke_admin?).with(@another_admin).returns(false)
        put :revoke_admin, params: { user_id: @another_admin.id }, format: :json
        expect(response).to be_forbidden
      end

      it 'updates the admin flag' do
        put :revoke_admin, params: { user_id: @another_admin.id }, format: :json
        @another_admin.reload
        expect(@another_admin).not_to be_admin
      end
    end

    context '.grant_admin' do
      before do
        @another_user = Fabricate(:coding_horror)
      end

      after do
        $redis.flushall
      end

      it "raises an error when the user doesn't have permission" do
        Guardian.any_instance.expects(:can_grant_admin?).with(@another_user).returns(false)
        put :grant_admin, params: { user_id: @another_user.id }, format: :json
        expect(response).to be_forbidden
      end

      it "returns a 404 if the username doesn't exist" do
        put :grant_admin, params: { user_id: 123123 }, format: :json
        expect(response).to be_forbidden
      end

      it 'updates the admin flag' do
        expect(AdminConfirmation.exists_for?(@another_user.id)).to eq(false)
        put :grant_admin, params: { user_id: @another_user.id }, format: :json
        expect(AdminConfirmation.exists_for?(@another_user.id)).to eq(true)
      end
    end

    context '.add_group' do
      let(:user) { Fabricate(:user) }
      let(:group) { Fabricate(:group) }

      it 'adds the user to the group' do
        post :add_group, params: {
          group_id: group.id, user_id: user.id
        }, format: :json

        expect(response).to be_success
        expect(GroupUser.where(user_id: user.id, group_id: group.id).exists?).to eq(true)

        group_history = GroupHistory.last

        expect(group_history.action).to eq(GroupHistory.actions[:add_user_to_group])
        expect(group_history.acting_user).to eq(@user)
        expect(group_history.target_user).to eq(user)

        # Doing it again doesn't raise an error
        post :add_group, params: {
          group_id: group.id, user_id: user.id
        }, format: :json

        expect(response).to be_success
      end
    end

    context '.primary_group' do
      let(:group) { Fabricate(:group) }

      before do
        @another_user = Fabricate(:coding_horror)
      end

      it "raises an error when the user doesn't have permission" do
        Guardian.any_instance.expects(:can_change_primary_group?).with(@another_user).returns(false)
        put :primary_group, params: {
          user_id: @another_user.id
        }, format: :json

        expect(response).to be_forbidden
      end

      it "returns a 404 if the user doesn't exist" do
        put :primary_group, params: {
          user_id: 123123
        }, format: :json

        expect(response).to be_forbidden
      end

      it "changes the user's primary group" do
        group.add(@another_user)
        put :primary_group, params: {
          user_id: @another_user.id, primary_group_id: group.id
        }, format: :json

        @another_user.reload
        expect(@another_user.primary_group_id).to eq(group.id)
      end

      it "doesn't change primary group if they aren't a member of the group" do
        put :primary_group, params: {
          user_id: @another_user.id, primary_group_id: group.id
        }, format: :json

        @another_user.reload
        expect(@another_user.primary_group_id).to be_nil
      end

      it "remove user's primary group" do
        group.add(@another_user)

        put :primary_group, params: {
          user_id: @another_user.id, primary_group_id: ""
        }, format: :json

        @another_user.reload
        expect(@another_user.primary_group_id).to be(nil)
      end
    end

    context '.trust_level' do
      before do
        @another_user = Fabricate(:coding_horror, created_at: 1.month.ago)
      end

      it "raises an error when the user doesn't have permission" do
        Guardian.any_instance.expects(:can_change_trust_level?).with(@another_user).returns(false)
        put :trust_level, params: {
          user_id: @another_user.id
        }, format: :json

        expect(response).not_to be_success
      end

      it "returns a 404 if the username doesn't exist" do
        put :trust_level, params: {
          user_id: 123123
        }, format: :json

        expect(response).not_to be_success
      end

      it "upgrades the user's trust level" do
        StaffActionLogger.any_instance.expects(:log_trust_level_change).with(@another_user, @another_user.trust_level, 2).once

        put :trust_level, params: {
          user_id: @another_user.id, level: 2
        }, format: :json

        @another_user.reload
        expect(@another_user.trust_level).to eq(2)
        expect(response).to be_success
      end

      it "raises no error when demoting a user below their current trust level (locks trust level)" do
        stat = @another_user.user_stat
        stat.topics_entered = SiteSetting.tl1_requires_topics_entered + 1
        stat.posts_read_count = SiteSetting.tl1_requires_read_posts + 1
        stat.time_read = SiteSetting.tl1_requires_time_spent_mins * 60
        stat.save!
        @another_user.update_attributes(trust_level: TrustLevel[1])

        put :trust_level, params: {
          user_id: @another_user.id, level: TrustLevel[0]
        }, format: :json

        expect(response).to be_success
        @another_user.reload
        expect(@another_user.trust_level_locked).to eq(true)
      end
    end

    describe '.revoke_moderation' do
      before do
        @moderator = Fabricate(:moderator)
      end

      it 'raises an error unless the user can revoke access' do
        Guardian.any_instance.expects(:can_revoke_moderation?).with(@moderator).returns(false)
        put :revoke_moderation, params: {
          user_id: @moderator.id
        }, format: :json

        expect(response).to be_forbidden
      end

      it 'updates the moderator flag' do
        put :revoke_moderation, params: {
          user_id: @moderator.id
        }, format: :json

        @moderator.reload
        expect(@moderator.moderator).not_to eq(true)
      end
    end

    context '.grant_moderation' do
      before do
        @another_user = Fabricate(:coding_horror)
      end

      it "raises an error when the user doesn't have permission" do
        Guardian.any_instance.expects(:can_grant_moderation?).with(@another_user).returns(false)
        put :grant_moderation, params: { user_id: @another_user.id }, format: :json
        expect(response).to be_forbidden
      end

      it "returns a 404 if the username doesn't exist" do
        put :grant_moderation, params: { user_id: 123123 }, format: :json
        expect(response).to be_forbidden
      end

      it 'updates the moderator flag' do
        put :grant_moderation, params: { user_id: @another_user.id }, format: :json
        @another_user.reload
        expect(@another_user.moderator).to eq(true)
      end
    end

    context '.reject_bulk' do
      let(:reject_me)     { Fabricate(:user) }
      let(:reject_me_too) { Fabricate(:user) }

      it 'does nothing without users' do
        UserDestroyer.any_instance.expects(:destroy).never
        delete :reject_bulk, format: :json
      end

      it "won't delete users if not allowed" do
        Guardian.any_instance.stubs(:can_delete_user?).returns(false)
        UserDestroyer.any_instance.expects(:destroy).never

        delete :reject_bulk, params: {
          users: [reject_me.id]
        }, format: :json
      end

      it "reports successes" do
        Guardian.any_instance.stubs(:can_delete_user?).returns(true)
        UserDestroyer.any_instance.stubs(:destroy).returns(true)

        delete :reject_bulk, params: {
          users: [reject_me.id, reject_me_too.id]
        }, format: :json

        expect(response).to be_success
        json = ::JSON.parse(response.body)
        expect(json['success'].to_i).to eq(2)
        expect(json['failed'].to_i).to eq(0)
      end

      context 'failures' do
        before do
          Guardian.any_instance.stubs(:can_delete_user?).returns(true)
        end

        it 'can handle some successes and some failures' do
          UserDestroyer.any_instance.stubs(:destroy).with(reject_me, anything).returns(false)
          UserDestroyer.any_instance.stubs(:destroy).with(reject_me_too, anything).returns(true)

          delete :reject_bulk, params: {
            users: [reject_me.id, reject_me_too.id]
          }, format: :json

          expect(response).to be_success
          json = ::JSON.parse(response.body)
          expect(json['success'].to_i).to eq(1)
          expect(json['failed'].to_i).to eq(1)
        end

        it 'reports failure due to a user still having posts' do
          UserDestroyer.any_instance.expects(:destroy).with(reject_me, anything).raises(UserDestroyer::PostsExistError)

          delete :reject_bulk, params: {
            users: [reject_me.id]
          }, format: :json

          expect(response).to be_success
          json = ::JSON.parse(response.body)
          expect(json['success'].to_i).to eq(0)
          expect(json['failed'].to_i).to eq(1)
        end
      end
    end

    context '.destroy' do
      let(:delete_me) { Fabricate(:user) }

      it "returns a 403 if the user doesn't exist" do
        delete :destroy, params: { id: 123123 }, format: :json
        expect(response).to be_forbidden
      end

      context "user has post" do
        let(:topic) { create_topic(user: delete_me) }

        before do
          _post = create_post(topic: topic, user: delete_me)
        end

        it "returns an error" do
          delete :destroy, params: { id: delete_me.id }, format: :json
          expect(response).to be_forbidden
        end

        it "doesn't return an error if delete_posts == true" do
          delete :destroy, params: { id: delete_me.id, delete_posts: true }, format: :json
          expect(response).to be_success
        end
      end

      it "deletes the user record" do
        UserDestroyer.any_instance.expects(:destroy).returns(true)
        delete :destroy, params: { id: delete_me.id }, format: :json
      end
    end

    context 'activate' do
      before do
        @reg_user = Fabricate(:inactive_user)
      end

      it "returns success" do
        put :activate, params: { user_id: @reg_user.id }, format: :json
        expect(response).to be_success
        json = ::JSON.parse(response.body)
        expect(json['success']).to eq("OK")
      end

      it "should confirm email even when the tokens are expired" do
        @reg_user.email_tokens.update_all(confirmed: false, expired: true)

        @reg_user.reload
        expect(@reg_user.email_confirmed?).to eq(false)

        put :activate, params: { user_id: @reg_user.id }, format: :json
        expect(response).to be_success

        @reg_user.reload
        expect(@reg_user.email_confirmed?).to eq(true)
      end
    end

    context 'log_out' do
      before do
        @reg_user = Fabricate(:user)
      end

      it "returns success" do
        put :log_out, params: { user_id: @reg_user.id }, format: :json
        expect(response).to be_success
        json = ::JSON.parse(response.body)
        expect(json['success']).to eq("OK")
      end

      it "returns 404 when user_id does not exist" do
        put :log_out, params: { user_id: 123123 }, format: :json
        expect(response).not_to be_success
      end
    end

    context 'silence' do
      before do
        @reg_user = Fabricate(:user)
      end

      it "raises an error when the user doesn't have permission" do
        Guardian.any_instance.expects(:can_silence_user?).with(@reg_user).returns(false)
        put :silence, params: { user_id: @reg_user.id }, format: :json
        expect(response).to be_forbidden
        @reg_user.reload
        expect(@reg_user).not_to be_silenced
      end

      it "returns a 403 if the user doesn't exist" do
        put :silence, params: { user_id: 123123 }, format: :json
        expect(response).to be_forbidden
      end

      it "punishes the user for spamming" do
        put :silence, params: { user_id: @reg_user.id }, format: :json
        expect(response).to be_success
        @reg_user.reload
        expect(@reg_user).to be_silenced
      end

      it "will set a length of time if provided" do
        future_date = 1.month.from_now.to_date
        put(
          :silence,
          params: {
            user_id: @reg_user.id,
            silenced_till: future_date
          },
          format: :json
        )
        @reg_user.reload
        expect(@reg_user.silenced_till).to eq(future_date)
      end

      it "will send a message if provided" do
        Jobs.stubs(:enqueue)
        Jobs.expects(:enqueue).with(
          :critical_user_email,
          has_entries(
            type: :account_silenced,
            user_id: @reg_user.id
          )
        )

        put(
          :silence,
          params: {
            user_id: @reg_user.id,
            message: "Email this to the user"
          },
          format: :json
        )
      end
    end

    context 'unsilence' do
      before do
        @reg_user = Fabricate(:user)
      end

      it "raises an error when the user doesn't have permission" do
        Guardian.any_instance.expects(:can_unsilence_user?).with(@reg_user).returns(false)
        put :unsilence, params: { user_id: @reg_user.id }, format: :json
        expect(response).to be_forbidden
      end

      it "returns a 403 if the user doesn't exist" do
        put :unsilence, params: { user_id: 123123 }, format: :json
        expect(response).to be_forbidden
      end

      it "punishes the user for spamming" do
        UserSilencer.expects(:unsilence).with(@reg_user, @user, anything)
        put :unsilence, params: { user_id: @reg_user.id }, format: :json
      end
    end

    context 'ip-info' do

      it "uses ipinfo.io webservice to retrieve the info" do
        Excon.expects(:get).with("https://ipinfo.io/123.123.123.123/json", read_timeout: 10, connect_timeout: 10)
        get :ip_info, params: { ip: "123.123.123.123" }, format: :json
      end

    end

    context "delete_other_accounts_with_same_ip" do

      it "works" do
        Fabricate(:user, ip_address: "42.42.42.42")
        Fabricate(:user, ip_address: "42.42.42.42")

        UserDestroyer.any_instance.expects(:destroy).twice

        delete :delete_other_accounts_with_same_ip, params: {
          ip: "42.42.42.42", exclude: -1, order: "trust_level DESC"
        }, format: :json
      end

    end

    context ".invite_admin" do
      it "doesn't work when not via API" do
        controller.stubs(:is_api?).returns(false)

        post :invite_admin, params: {
          name: 'Bill', username: 'bill22', email: 'bill@bill.com'
        }, format: :json

        expect(response).not_to be_success
      end

      it 'should invite admin' do
        controller.stubs(:is_api?).returns(true)
        Jobs.expects(:enqueue).with(:critical_user_email, anything).returns(true)

        post :invite_admin, params: {
          name: 'Bill', username: 'bill22', email: 'bill@bill.com'
        }, format: :json

        expect(response).to be_success

        u = User.find_by_email('bill@bill.com')
        expect(u.name).to eq("Bill")
        expect(u.username).to eq("bill22")
        expect(u.admin).to eq(true)
      end

      it "doesn't send the email with send_email falsy" do
        controller.stubs(:is_api?).returns(true)
        Jobs.expects(:enqueue).with(:user_email, anything).never

        post :invite_admin, params: {
          name: 'Bill', username: 'bill22', email: 'bill@bill.com', send_email: '0'
        }, format: :json

        expect(response).to be_success
        json = ::JSON.parse(response.body)
        expect(json["password_url"]).to be_present
      end
    end

    context 'remove_group' do
      it "also clears the user's primary group" do
        g = Fabricate(:group)
        u = Fabricate(:user, primary_group: g)
        delete :remove_group, params: { group_id: g.id, user_id: u.id }, format: :json

        expect(u.reload.primary_group).to be_nil
      end
    end
  end

  context '#sync_sso' do
    let(:sso) { SingleSignOn.new }
    let(:sso_secret) { "sso secret" }

    before do
      log_in(:admin)

      SiteSetting.email_editable = false
      SiteSetting.enable_sso = true
      SiteSetting.sso_overrides_email = true
      SiteSetting.sso_overrides_name = true
      SiteSetting.sso_overrides_username = true
      SiteSetting.sso_secret = sso_secret
      sso.sso_secret = sso_secret
    end

    it 'can sync up with the sso' do
      sso.name = "Bob The Bob"
      sso.username = "bob"
      sso.email = "bob@bob.com"
      sso.external_id = "1"

      user = DiscourseSingleSignOn.parse(sso.payload)
        .lookup_or_create_user

      sso.name = "Bill"
      sso.username = "Hokli$$!!"
      sso.email = "bob2@bob.com"

      post :sync_sso, params: Rack::Utils.parse_query(sso.payload), format: :json
      expect(response).to be_success

      user.reload
      expect(user.email).to eq("bob2@bob.com")
      expect(user.name).to eq("Bill")
      expect(user.username).to eq("Hokli")
    end

    it 'should create new users' do
      sso.name = "Dr. Claw"
      sso.username = "dr_claw"
      sso.email = "dr@claw.com"
      sso.external_id = "2"
      post :sync_sso, params: Rack::Utils.parse_query(sso.payload), format: :json
      expect(response).to be_success

      user = User.find_by_email('dr@claw.com')
      expect(user).to be_present
      expect(user.ip_address).to be_blank
    end

    it 'should return the right message if the record is invalid' do
      sso.email = ""
      sso.name = ""
      sso.external_id = "1"

      post :sync_sso, params: Rack::Utils.parse_query(sso.payload), format: :json
      expect(response.status).to eq(403)
      expect(JSON.parse(response.body)["message"]).to include("Primary email can't be blank")
    end
  end
end
