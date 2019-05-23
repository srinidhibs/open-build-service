require 'rails_helper'

# WARNING: If you change tests make sure you uncomment this line
# and start a test backend. Some of the actions
# require real backend answers for projects/packages.
# CONFIG['global_write_through'] = true

RSpec.describe Issue, vcr: true do
  describe '#fetch_issues' do
    let!(:issue_tracker) { create(:issue_tracker) }
    let!(:issue) { create(:issue, issue_tracker: issue_tracker) }

    before do
      allow(IssueTracker).to receive(:find_by).and_return(issue_tracker)
      allow(issue_tracker).to receive(:fetch_issues)
    end

    subject! { issue.fetch_issues }

    it 'fetches the issues' do
      expect(issue_tracker).to have_received(:fetch_issues)
    end
  end

  describe 'validations' do
    let!(:issue_tracker) { create(:issue_tracker) }
    let!(:issue) { create(:issue, name: '1234', issue_tracker: issue_tracker) }
    let!(:issue_v1) { create(:issue, name: 'B-1234', issue_tracker: issue_tracker) }
    let!(:issue_tracker_cve) { create(:issue_tracker, name: 'cve_tracker', regex: '(?:cve|CVE)-(\d\d\d\d-\d+)') }
    let!(:issue_cve) { create(:issue, name: 'CVE-2019-12345', issue_tracker: issue_tracker_cve) }

    it { expect(issue).to be_valid }
    it { expect(issue_v1).to be_valid }
    it { expect(issue_cve).to be_valid }
  end
end
