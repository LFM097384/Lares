// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Lares Circle';

  @override
  String get chatCollapse => 'Hide messages';

  @override
  String get chatComposerHint => 'Say something, or drop in a picture';

  @override
  String get chatEmpty =>
      'It\'s quiet here. Anything you want to say, or a picture, can go here.';

  @override
  String get chatExpand => 'Show messages';

  @override
  String get chatImageMissing => 'This picture didn\'t come through';

  @override
  String get chatImageOpen => 'Picture, tap to open it larger';

  @override
  String get chatImagePickFailed => 'Couldn\'t open the picture';

  @override
  String get chatImagePickUnsupported =>
      'Picking pictures isn\'t supported in this version yet';

  @override
  String get chatImageSendFailed => 'That picture didn\'t send';

  @override
  String get chatImageViewer => 'Full-size picture, tap outside to close';

  @override
  String get chatImageViewerClose => 'Close the full-size picture';

  @override
  String chatRemaining(int left) {
    String _temp0 = intl.Intl.pluralLogic(
      left,
      locale: localeName,
      other: '$left characters left',
      one: '1 character left',
    );
    return '$_temp0';
  }

  @override
  String get chatSend => 'Send';

  @override
  String get chatSendFailed => 'Didn\'t send';

  @override
  String get chatSendImage => 'Send a picture';

  @override
  String get chatUnread => 'New messages';

  @override
  String get commonCancel => 'Never mind';

  @override
  String get commonClose => 'Close';

  @override
  String get commonConfirm => 'OK';

  @override
  String get commonCopied => 'Copied';

  @override
  String get commonCopy => 'Copy';

  @override
  String get commonDone => 'Done';

  @override
  String get commonGotIt => 'Got it';

  @override
  String get commonListSeparator => ', ';

  @override
  String get commonNoThanks => 'No thanks';

  @override
  String get commonSave => 'Save';

  @override
  String get e2eeConfirmBody =>
      'Encryption only works when **everyone in the circle turns it on**. If you are the only one, they will not be able to hear you and you will not be able to hear them — your voices never reach the same lock. Talk to the circle first and turn it on together.';

  @override
  String get e2eeConfirmTitle => 'Everyone in the circle has to turn this on';

  @override
  String get e2eeConfirmYes => 'We agreed — turn it on';

  @override
  String get e2eeCostNotice =>
      'Once on: the server sees nothing, so **transcription is off**, and the **AI Lares** is **unavailable** in this circle (it only works in circles without encryption).';

  @override
  String get e2eeEveryoneNotice =>
      'Everyone in the circle has to turn this on, or you will not be able to hear each other.';

  @override
  String get e2eeKeyLocalNotice =>
      'The key is derived from your circle passphrase, stays on this device, and never reaches the server.';

  @override
  String get e2eeTitle => 'End-to-end encryption';

  @override
  String get homeAddCircle => 'New circle';

  @override
  String get homeAddCircleConfirm => 'Make one';

  @override
  String get homeAddCircleHint => 'Family, close friends, study group…';

  @override
  String get homeAvailable => 'I\'m free';

  @override
  String get homeAvailableOffDesc =>
      'Put it out there so your circles know you can talk · long-press to pick circles';

  @override
  String homeAvailableOnDesc(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n circles can see you',
      one: '1 circle can see you',
    );
    return '$_temp0 · whoever comes first is who you talk to, and once you\'re in, the others stop seeing you';
  }

  @override
  String get homeAvailablePickBody =>
      'Once you put it out there, people in these circles will see that you\'re free.\nWhoever reaches you first is who you talk to — from that moment the other circles stop seeing you.';

  @override
  String get homeAvailablePickConfirm => 'Just these';

  @override
  String get homeAvailablePickTitle => 'Which circles can see you';

  @override
  String get homeCircleEmpty => 'Nobody here yet — go in and wait?';

  @override
  String homeCircleOnline(int online) {
    String _temp0 = intl.Intl.pluralLogic(
      online,
      locale: localeName,
      other: '$online people here',
      one: '1 person here',
    );
    return '$_temp0';
  }

  @override
  String homeCircleOnlineAndWaiting(int online, String waitingNames) {
    String _temp0 = intl.Intl.pluralLogic(
      online,
      locale: localeName,
      other: '$online people here',
      one: '1 person here',
    );
    return '$_temp0 · $waitingNames free to talk';
  }

  @override
  String homeCircleOnlineWithNames(int online, String names) {
    String _temp0 = intl.Intl.pluralLogic(
      online,
      locale: localeName,
      other: '$online people here',
      one: '1 person here',
    );
    return '$_temp0 · $names';
  }

  @override
  String homeCircleWaitingOnly(String waitingNames) {
    return '$waitingNames — free to talk, waiting for someone';
  }

  @override
  String get homeDeleteCircle => 'Delete this circle';

  @override
  String get homeEmptyRoomHint => 'Tap a circle on the left to go in';

  @override
  String get homeInviteBody =>
      'Send this link to a friend — one tap and they\'re in (they can also paste it in the app):';

  @override
  String get homeInvitedCircleFallback => 'A friend\'s circle';

  @override
  String get homeInviteFriends => 'Invite friends';

  @override
  String get homeInviteFriendsDesc => 'Copy the invite link and send it over';

  @override
  String get homeInviteIncludePasscode => 'Put the passphrase in the link';

  @override
  String get homeInviteIncludePasscodeE2ee =>
      '⚠️ This circle is end-to-end encrypted — the passphrase is the key. If the link gets forwarded or screenshotted, the conversations are no longer private.';

  @override
  String get homeInviteIncludePasscodeHint =>
      'They will not have to ask you for it separately';

  @override
  String homeInviteTitle(String circleName) {
    return 'Invite friends to “$circleName”';
  }

  @override
  String get homeJoinCircle => 'Join';

  @override
  String homeKickedBy(String who) {
    return '$who removed you from the room';
  }

  @override
  String get homeKickedByAdmin => 'An admin';

  @override
  String get homeKnockModeConfirmBody =>
      'This is a setting for the whole circle, not just for you — change it and it changes for everyone. Anyone in the circle can change it back, too.';

  @override
  String get homeKnockModeConfirmTitle => 'This changes it for everyone';

  @override
  String get homeKnockModeConfirmYes => 'Change it';

  @override
  String get homeKnockModeDesc =>
      'When on, people outside the circle need someone inside to let them in';

  @override
  String get homeKnockModeEveryoneNotice =>
      'The whole circle shares this one setting — if you change it, you change it for everyone.';

  @override
  String get homeKnockModeOff => 'Knock mode: off (tap to turn on)';

  @override
  String get homeKnockModeOn => 'Knock mode: on (tap to turn off)';

  @override
  String get homePasteInvite => 'Have an invite link? Paste it';

  @override
  String get homePasteInviteHint => 'lares://circle/… or a circle id';

  @override
  String get homePasteInvitePasscode =>
      'Circle passcode (if your friend sent one)';

  @override
  String get homePasteInvitePasscodeHint =>
      'Leave it blank if you don\'t have one — you can add it later';

  @override
  String get homePasteInviteTitle => 'Paste an invite link';

  @override
  String get homePrimaryCircleAlready => 'Already your main circle';

  @override
  String get homePrimaryCircleAlreadyDesc =>
      'The widget, quick settings and the tray all drop you into this one';

  @override
  String get homePrimaryCircleSet => 'Make this the main circle';

  @override
  String get homePrimaryCircleSetDesc =>
      'One tap on the home screen widget takes you straight here';

  @override
  String get homePrimaryCircleTooltip =>
      'Main circle · one tap from the widget';

  @override
  String get homeRename => 'Change nickname';

  @override
  String get homeRenameConfirm => 'Use this';

  @override
  String get homeRenameHint => 'Nickname';

  @override
  String get homeRenameTitle => 'What should the circle call you?';

  @override
  String get moderationBlock => 'Block this person';

  @override
  String get moderationBlockHint =>
      'You won\'t hear their voice or see their messages';

  @override
  String get moderationBlockShort => 'Block';

  @override
  String get moderationNoUserId => 'Couldn\'t find a user ID';

  @override
  String get moderationSuggestBlockBody =>
      'Once blocked, you won\'t hear their voice or see their messages.';

  @override
  String get moderationSuggestBlockTitle => 'Block them too?';

  @override
  String get moderationUnblock => 'Unblock';

  @override
  String get moderationUnblockHint => 'Their voice and messages come back';

  @override
  String noteListen(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count notes (hold to leave one)',
      one: '1 note (hold to leave one)',
      zero: 'Hold to leave a note',
    );
    return '$_temp0';
  }

  @override
  String get noteRecordHint => 'Hold to leave a note';

  @override
  String get p2pCaveatHasTurn =>
      'Also, about a quarter of network setups can\'t connect directly. Those will go through the relay server you set up.';

  @override
  String get p2pCaveatNoTurn =>
      'Also, about a quarter of network setups can\'t connect directly. Those need a relay server (TURN) filled in under settings.';

  @override
  String get p2pCaveats =>
      '⚠️ One to one only, and there\'s no text, no images and no encryption badge here — those all need a server.';

  @override
  String p2pCharCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count characters',
      one: '1 character',
    );
    return '$_temp0';
  }

  @override
  String get p2pCodeCopied => 'Connect code copied. Send it over.';

  @override
  String get p2pCodeSendBack => '② Send this back to them';

  @override
  String get p2pCodeSendToPeer => '① Send this to the other person';

  @override
  String get p2pConnect => 'Connect';

  @override
  String get p2pCopy => 'Copy';

  @override
  String get p2pErrorCorrupted =>
      'The connect code is incomplete — part of it probably got lost in the copy.';

  @override
  String get p2pErrorNotLaresCode =>
      'That text isn\'t a Lares connect code. Worth another look.';

  @override
  String get p2pErrorVersionMismatch =>
      'Their Lares version is too far from yours. Update and try again.';

  @override
  String get p2pErrorWrongKind =>
      'Wrong one — that\'s an opening code. You want the answer code they sent back.';

  @override
  String get p2pNoServerBody =>
      'You and the other person trade one connect code, and the audio goes straight between the two devices.\nSend the code however you like — a chat app, a text message, or just read it out.';

  @override
  String get p2pNoServerTitle => 'No server involved';

  @override
  String get p2pPasteFromClipboard => 'Paste from clipboard';

  @override
  String get p2pPasteIncomingLabel => '① Paste the code they sent you';

  @override
  String get p2pPasteReplyLabel => '② Paste the code they sent back';

  @override
  String get p2pPreparing => 'Getting the connection details ready…';

  @override
  String get p2pRoleAnswererBody =>
      'Paste in the code they sent, then send back the one it makes.';

  @override
  String get p2pRoleAnswererTitle => 'They sent me a code';

  @override
  String get p2pRoleMeshBody =>
      'The server hands the connect codes around, so nobody has to pass them by hand. One person is picked automatically to relay the audio — a computer first, since it\'s plugged in and has a steadier connection.';

  @override
  String get p2pRoleMeshTitle => 'Everyone in the circle (up to 4)';

  @override
  String get p2pRoleOffererBody =>
      'Make a connect code and send it over, then wait for the one they send back.';

  @override
  String get p2pRoleOffererTitle => 'I\'ll start';

  @override
  String get p2pStatusClosed => 'Disconnected';

  @override
  String get p2pStatusConnected => 'Connected. Go ahead and talk.';

  @override
  String get p2pStatusConnecting => 'Connecting…';

  @override
  String get p2pStatusFailed => 'Couldn\'t connect';

  @override
  String get p2pStatusWaitingForPeer => 'Waiting on the other side';

  @override
  String get p2pTitle => 'Direct call';

  @override
  String get policyAgree => 'I have read this and agree';

  @override
  String get policyDecline => 'I do not agree';

  @override
  String get policyOwnContentBody =>
      'Everything you say, send, or share is on you. Joining a circle means accepting that.';

  @override
  String get policyOwnContentTitle => 'You\'re responsible for what you post';

  @override
  String get policyRemovalBody =>
      'People who break these rules are removed from the circle; serious cases are banned from the service for good. Once we get a report, we finish handling it and tell you the outcome within 24 hours.';

  @override
  String get policyRemovalTitle => 'People who break the rules are removed';

  @override
  String get policySummary =>
      'This is a voice space for small circles of people who already know each other. For it to stay somewhere you want to be, a few things have to hold.';

  @override
  String get policyTitle => 'Community content rules';

  @override
  String get policyToolsBody =>
      'You can block someone on this device at any time; after that you stop receiving anything from them. To report someone, pick them in the member list, or press and hold the specific message.';

  @override
  String get policyToolsTitle => 'You have tools';

  @override
  String get policyZeroToleranceBody =>
      'Harassment, personal attacks, hateful or discriminatory speech, sexual content, violent content, and illegal material aren\'t allowed here. That covers voice, text, pictures, and location, with no exceptions.';

  @override
  String get policyZeroToleranceTitle => 'Zero tolerance for abuse';

  @override
  String recordingAlsoRecording(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count other people in the room are recording',
      one: '1 other person in the room is recording',
    );
    return '$_temp0';
  }

  @override
  String get recordingConsentEveryoneNotified =>
      'Everyone in the room is told right away that you\'re the one recording.';

  @override
  String get recordingConsentLocalOnly =>
      'Audio is transcribed to text and kept on this device. Nothing is uploaded.';

  @override
  String recordingConsentMemberCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'There are $count people in the room right now.',
      one: 'There\'s 1 person in the room right now.',
    );
    return '$_temp0';
  }

  @override
  String get recordingConsentPersistentNotice =>
      'While you record, everyone sees a recording notice they can\'t dismiss.';

  @override
  String get recordingConsentReconsider => 'Let me think';

  @override
  String get recordingConsentStart => 'Start recording';

  @override
  String get recordingConsentTitle => 'Start recording?';

  @override
  String recordingElapsedHours(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: '$hours hours so far',
      one: '1 hour so far',
    );
    return '$_temp0';
  }

  @override
  String recordingElapsedHoursMinutes(int hours, int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: '$hours hours',
      one: '1 hour',
    );
    String _temp1 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes minutes',
      one: '1 minute',
    );
    return '$_temp0 $_temp1 so far';
  }

  @override
  String recordingElapsedMinutes(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes minutes so far',
      one: '1 minute so far',
    );
    return '$_temp0';
  }

  @override
  String recordingElapsedSeconds(int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: '$seconds seconds so far',
      one: '1 second so far',
    );
    return '$_temp0';
  }

  @override
  String get recordingListSeparator => ', ';

  @override
  String get recordingNobodyRecording => 'Nobody here is recording';

  @override
  String get recordingNoticeAlreadyInProgress =>
      'A recording is already running. Stop it first.';

  @override
  String recordingNoticeArmingTimeout(int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: '$seconds seconds',
      one: '1 second',
    );
    return 'Couldn\'t confirm the room was told, so recording was cancelled (no reply from the server after $_temp0)';
  }

  @override
  String get recordingNoticeCircleIdEmpty =>
      'No circle ID, so recording can\'t start';

  @override
  String get recordingNoticeDisconnected =>
      'Lost the signaling connection. Trying to get it back; recording will stop on its own if it doesn\'t come back';

  @override
  String recordingNoticeGraceExpired(int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: '$seconds seconds',
      one: '1 second',
    );
    return 'Signaling has been down for more than $_temp0. There\'s no way to tell whether the room still knows, so recording stopped';
  }

  @override
  String get recordingNoticeRemovedFromRoom =>
      'You were removed from the room, so recording stopped — the room wouldn\'t have known';

  @override
  String get recordingNoticeServerMarkedInactive =>
      'The server has you marked as not recording, so recording stopped — the room wouldn\'t have known';

  @override
  String get recordingNoticeSignalingSilent =>
      'No signaling messages for a while. Confirming the recording status again';

  @override
  String get recordingNoticeStateOutOfSync =>
      'Signaling state is out of sync. Confirming the recording status again';

  @override
  String recordingSemanticsLabel(String body) {
    return 'Recording notice: $body';
  }

  @override
  String recordingSeveralRecording(String name, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count people are recording, including $name',
      one: '$name is recording',
    );
    return '$_temp0';
  }

  @override
  String recordingSomeoneRecording(String name) {
    return '$name is recording';
  }

  @override
  String get recordingStatusUnconfirmed => 'Recording status unconfirmed';

  @override
  String get recordingStop => 'Stop recording';

  @override
  String get recordingYouAreRecording => 'You\'re recording';

  @override
  String get reportAccepted => 'Sent. We\'ll deal with it within 24 hours';

  @override
  String get reportAction => 'Report';

  @override
  String get reportActionHint =>
      'Tell us what happened — we deal with it within 24 hours';

  @override
  String get reportDeliveryBody =>
      'We\'ve written up the report and opened your email app. Check it over and hit send.\nIf the email didn\'t open, the report is on your clipboard too — start a new message, paste it, and send it to:';

  @override
  String get reportDeliveryFollowUp =>
      'We resolve reports within 24 hours and reply to this address.';

  @override
  String get reportDeliveryTitle => 'One last step: send the email';

  @override
  String reportDialogTitle(String targetName) {
    return 'Report $targetName';
  }

  @override
  String get reportMessageAction => 'Report this message';

  @override
  String get reportNoteHint => 'Anything to add (optional)';

  @override
  String get reportPickReason =>
      'Pick the closest one. We read every report and get back to you.';

  @override
  String get reportReasonHarassment => 'Harassment or personal attacks';

  @override
  String get reportReasonHateSpeech => 'Hate speech or discrimination';

  @override
  String get reportReasonIllegal => 'Illegal or dangerous activity';

  @override
  String get reportReasonOther => 'Something else';

  @override
  String get reportReasonSexualContent => 'Sexual or suggestive content';

  @override
  String get reportReasonSpam => 'Spam or flooding';

  @override
  String get reportReasonViolence => 'Violence or graphic content';

  @override
  String get reportSubmit => 'Submit report';

  @override
  String get roomAloneHere => 'Just you in here. Stay a bit?';

  @override
  String get roomBackToRoom => 'Back to the room';

  @override
  String get roomBlockedSemantics => 'This person is blocked';

  @override
  String get roomEmpty => 'Nobody here yet. Sit a while?';

  @override
  String get roomErrorGeneric => 'Something went wrong';

  @override
  String get roomJoining => 'Going in…';

  @override
  String get roomPasscodeHint => 'Passcode';

  @override
  String get roomPasscodeRetry => 'Try again';

  @override
  String get roomPasscodeSavedElsewhere =>
      'Passcode saved. This server currently uses a shared token, so you\'ll need to switch it to per-circle passcodes in settings before it works.';

  @override
  String get roomJoinLatencyTooltip => 'How long it took to get in';

  @override
  String get roomKickBody =>
      'They\'ll be moved out of the room. They can come back later — this isn\'t a ban.';

  @override
  String get roomKickConfirm => 'Remove';

  @override
  String get roomKickMember => 'Remove from room';

  @override
  String get roomKickMemberHint =>
      'They can come back later, this isn\'t a ban';

  @override
  String roomKickTitle(String name) {
    return 'Remove $name from the room?';
  }

  @override
  String get roomKnockAllow => 'Let them in';

  @override
  String get roomKnockDeny => 'Not now';

  @override
  String get roomKnocking => 'Knocking, waiting for someone to answer…';

  @override
  String roomKnockWants(String name) {
    return '$name wants to come in';
  }

  @override
  String get roomLeave => 'Leave';

  @override
  String get roomLocationMap => 'Shared location map';

  @override
  String get roomMute => 'Mute';

  @override
  String roomPeopleHere(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count people here',
      one: '1 person here',
      zero: 'Nobody here',
    );
    return '$_temp0';
  }

  @override
  String get roomStatusBusy => 'Busy';

  @override
  String get roomStatusEars => 'Just listening';

  @override
  String get roomStatusFree => 'Free to talk';

  @override
  String get roomStatusPick => 'My status';

  @override
  String get roomUnmute => 'Speak';

  @override
  String get settingsAuthModeCircle => 'Per-circle passcode';

  @override
  String get settingsAuthModeNone => 'No passcode';

  @override
  String get settingsAuthModeToken => 'Shared token';

  @override
  String get settingsBackground => 'Keep running in the background';

  @override
  String get settingsBackgroundDenied =>
      'Allow this app to ignore battery optimization in system settings';

  @override
  String get settingsBackgroundGranted =>
      'Background running is allowed. On some Android skins you may also need to turn on auto-start.';

  @override
  String get settingsBackgroundIos =>
      'While you\'re in a room, iOS keeps the app alive with background audio. Nothing to set up.';

  @override
  String get settingsBackgroundSub =>
      'Stay connected while idle: battery optimization exemption / background audio';

  @override
  String get settingsContentPolicy => 'Community content rules';

  @override
  String get settingsContentPolicySub => 'What we ask of what gets shared here';

  @override
  String get settingsDnd => 'Do not disturb hours';

  @override
  String get settingsDndConfirm => 'That\'s it';

  @override
  String get settingsDndFrom => 'From';

  @override
  String get settingsDndOff => 'Off (knocks still come through)';

  @override
  String get settingsDndTo => 'To';

  @override
  String get settingsDndTurnOff => 'Turn off';

  @override
  String get settingsGroupCircle => 'This circle';

  @override
  String get settingsGroupMe => 'You';

  @override
  String get settingsGroupSafety => 'Somewhere you can stay';

  @override
  String get settingsGroupSound => 'Sound and interruptions';

  @override
  String get settingsHomeWidget => 'Put a circle on the home screen';

  @override
  String get settingsHomeWidgetAndroidStep1 =>
      'Press and hold an empty spot on the home screen';

  @override
  String get settingsHomeWidgetAndroidStep2 => 'Tap Widgets';

  @override
  String get settingsHomeWidgetAndroidStep3 => 'Find Lares Circle';

  @override
  String get settingsHomeWidgetAndroidStep4 => 'Drag it onto the home screen';

  @override
  String get settingsHomeWidgetGuideTitle => 'Adding it to the home screen';

  @override
  String get settingsHomeWidgetIosStep1 =>
      'Press and hold an empty spot on the home screen until the icons jiggle';

  @override
  String get settingsHomeWidgetIosStep2 => 'Tap the + in the top left corner';

  @override
  String get settingsHomeWidgetIosStep3 => 'Search for \"Lares Circle\"';

  @override
  String get settingsHomeWidgetIosStep4 =>
      'Pick a size — swipe left or right to see the others';

  @override
  String get settingsHomeWidgetIosStep5 =>
      'Tap Add Widget, then Done in the top right';

  @override
  String get settingsHomeWidgetPhoneOnly =>
      'Home screen widgets are a phone thing. This device doesn\'t have them.';

  @override
  String get settingsHomeWidgetSub =>
      'One tap from the home screen into your main circle';

  @override
  String get settingsIdentityExportBody =>
      'Open the same place over there and paste it into the box below. It only holds your identity and name — no circle passphrases.';

  @override
  String get settingsIdentityExportTitle =>
      'Give this string to the other device';

  @override
  String get settingsIdentityImportAction => 'Use this identity';

  @override
  String get settingsIdentityImportBad =>
      'That does not look like an identity string. Try copying it again.';

  @override
  String get settingsIdentityImportHint => 'lares-id-v1:…';

  @override
  String get settingsIdentityImportRestart =>
      'Saved — but restart Lares before it counts. This connection is still online under the old identity.';

  @override
  String get settingsIdentityImportTitle => 'Or paste one in';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsLanguageSystem => 'Follow system';

  @override
  String get settingsMyName => 'Your name';

  @override
  String get settingsMyNameHint => 'Nickname';

  @override
  String get settingsMyNameTitle => 'What should everyone call you?';

  @override
  String get settingsNoiseEnhanced => 'Enhanced';

  @override
  String get settingsNoiseOff => 'Off';

  @override
  String get settingsNoiseStandard => 'Standard';

  @override
  String get settingsNoiseSuppression => 'Noise suppression';

  @override
  String get settingsPickPrimaryCircle => 'Which one is the main circle?';

  @override
  String get settingsPrimaryCircle => 'Main circle';

  @override
  String get settingsPrimaryCircleNone => 'No circles yet';

  @override
  String settingsPrimaryCircleSub(String name) {
    return '$name\nThe widget, quick settings and the tray all open this one';
  }

  @override
  String get settingsRecording => 'Recording and transcripts';

  @override
  String get settingsRecordingOff =>
      'Off by default; everyone sees a notice when it\'s on';

  @override
  String get settingsRecordingOn =>
      'Recording — everyone in the room can see the notice';

  @override
  String get settingsRecordingStart => 'Start recording';

  @override
  String get settingsRecordingStartFailed => 'Recording didn\'t start';

  @override
  String get settingsRecordingStop => 'Stop recording';

  @override
  String get settingsSameIdentity => 'Use this identity on another device';

  @override
  String get settingsSameIdentitySub =>
      'Your computer and phone count as one person, and will not knock each other offline';

  @override
  String get settingsServer => 'Server and passcode';

  @override
  String get settingsServerAdd => 'Add a server';

  @override
  String get settingsServerAuthLabel => 'Needs a passcode';

  @override
  String get settingsServerBiometricFailed =>
      'Not verified, so it stays closed';

  @override
  String get settingsServerBiometricReason => 'View or change server passcodes';

  @override
  String get settingsServerBuiltIn => 'Default (built in)';

  @override
  String get settingsServerCircleId => 'Circle ID';

  @override
  String get settingsServerCirclePasscode => 'Circle passcode';

  @override
  String settingsServerCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count servers',
      one: '1 server',
    );
    return '$_temp0';
  }

  @override
  String get settingsServerDefaultLabel => 'My server';

  @override
  String get settingsServerDelete => 'Delete';

  @override
  String get settingsServerEdit => 'Edit';

  @override
  String get settingsServerEditTitle => 'Edit server';

  @override
  String get settingsServerListTitle => 'Servers';

  @override
  String get settingsServerName => 'Name';

  @override
  String get settingsServerNameHint => 'e.g. the VPS at home';

  @override
  String get settingsServerPlaintextWarning =>
      'Passcodes are kept as plain text in this device\'s settings, not encrypted. Anyone who can read the files on this device can read them — be careful on a shared device.';

  @override
  String get settingsServerSave => 'Save';

  @override
  String get settingsServerSaved =>
      'Saved. Restart the app for it to take effect.';

  @override
  String get settingsServerTest => 'Test connection';

  @override
  String get settingsServerTokenHint => 'The server\'s LARES_AUTH_TOKEN';

  @override
  String get settingsServerUrl => 'Address';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsWifiOnlyHq => 'High quality on Wi-Fi only';

  @override
  String get settingsWifiOnlyHqSub =>
      'Uses a lower bitrate on mobile data to save it';

  @override
  String get updateAndroidInstallerOpened =>
      'The system installer is open. If it says installing unknown apps is blocked, allow Lares Circle to install apps in the settings screen it offers, then try again.';

  @override
  String get updateAutoCheckSubtitle =>
      'Checks quietly and only speaks up when there\'s a new version. Installing always needs your confirmation.';

  @override
  String get updateAutoCheckTitle => 'Check for updates at startup';

  @override
  String get updateCheckNow => 'Check now';

  @override
  String updateCurrentVersion(String version) {
    return 'Current v$version';
  }

  @override
  String get updateDownload => 'Download update';

  @override
  String get updateDownloading => 'Downloading…';

  @override
  String updateDownloadWithSize(String size) {
    return 'Download update ($size MB)';
  }

  @override
  String get updateErrAndroidInstallerNotOpened =>
      'The system installer didn\'t open.';

  @override
  String updateErrAndroidLaunchFailed(String detail) {
    return 'Couldn\'t open the system installer: $detail';
  }

  @override
  String get updateErrChecksum =>
      'The checksum doesn\'t match. The file may be damaged or tampered with, so it was deleted.';

  @override
  String updateErrDownloadFailed(String detail) {
    return 'The download failed: $detail';
  }

  @override
  String updateErrDownloadHttp(int code) {
    return 'The download failed (HTTP $code).';
  }

  @override
  String get updateErrDownloadTimeout => 'The download timed out.';

  @override
  String updateErrGithubRefused(int code) {
    return 'GitHub turned down the request ($code). Try again later.';
  }

  @override
  String updateErrHttp(int code) {
    return 'The check didn\'t go through (HTTP $code).';
  }

  @override
  String get updateErrInstallFailed => 'The installation didn\'t go through.';

  @override
  String get updateErrIosCannotInstall =>
      'iOS can\'t install an update package from inside the app.';

  @override
  String get updateErrIosNoSelfUpdate =>
      'iOS can\'t update the app from inside itself. Update through TestFlight, or sideload the new .ipa from a computer.';

  @override
  String get updateErrMalformed =>
      'The release data came back in an unexpected shape and couldn\'t be read.';

  @override
  String get updateErrNoAsset =>
      'There\'s no downloadable package for this platform.';

  @override
  String get updateErrNoReleases => 'The repository has no releases yet.';

  @override
  String get updateErrNotDownloaded => 'There\'s no downloaded package yet.';

  @override
  String get updateErrOffline =>
      'No network connection, so updates can\'t be checked right now.';

  @override
  String get updateErrRateLimited =>
      'The GitHub API quota is used up (60 requests per hour when signed out). Try again later.';

  @override
  String updateErrRateLimitedUntil(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other:
          'The GitHub API quota is used up (60 requests per hour when signed out), it comes back in about $minutes minutes. Try again later.',
      one:
          'The GitHub API quota is used up (60 requests per hour when signed out), it comes back in about 1 minute. Try again later.',
    );
    return '$_temp0';
  }

  @override
  String updateErrSizeMismatch(int expected, int actual) {
    return 'The downloaded file is the wrong size (expected $expected bytes, got $actual), so it was deleted.';
  }

  @override
  String get updateErrTimeout =>
      'The network timed out, so updates can\'t be checked right now.';

  @override
  String updateErrUnknownVersion(String version) {
    return 'Couldn\'t make sense of the current version number ($version)';
  }

  @override
  String updateErrWinLaunchFailed(String detail) {
    return 'Couldn\'t start the installer: $detail';
  }

  @override
  String get updateErrWinNoInstallDir =>
      'The install folder couldn\'t be found. You can download the new version and install over the old one yourself.';

  @override
  String get updateErrWinNotWritable =>
      'The install folder isn\'t writable, usually because Lares sits in Program Files and isn\'t running as administrator. Download the new version manually, or move Lares into your user folder and try again.';

  @override
  String updateErrWinPackageInvalid(String name) {
    return 'The update package looks wrong ($name wasn\'t in it). Nothing was changed, your current version is untouched.';
  }

  @override
  String updateErrWinProbeFailed(String detail) {
    return 'Couldn\'t tell whether the install folder is writable: $detail';
  }

  @override
  String updateErrWinUnzipFailed(String detail) {
    return 'Unpacking the update failed: $detail';
  }

  @override
  String get updateGotIt => 'Got it';

  @override
  String get updateInstallAndRestart => 'Install and restart';

  @override
  String get updateInstallConfirmBody =>
      'Lares will close, replace its program files and start again on its own.\nIf you\'re talking in a circle, you\'ll be disconnected first.';

  @override
  String get updateInstallConfirmTitle => 'Install the update now?';

  @override
  String get updateInstallNow => 'Install now';

  @override
  String get updateInstallStarted => 'Installation started.';

  @override
  String get updateIntegrityFull =>
      'Integrity: the file size matches, and the SHA-256 matches the checksum published in the release notes.';

  @override
  String get updateIntegrityNone =>
      'Integrity: nothing could be verified, the release gave no file size.';

  @override
  String get updateIntegritySizeOnly =>
      'Integrity: only the file size was checked against what GitHub reports. The release notes gave no checksum, so the contents can\'t be verified; transport safety relies on HTTPS.';

  @override
  String get updateLater => 'Later';

  @override
  String get updateMacosDragToApps =>
      'The new version is open in Finder:\n1. Quit Lares if it\'s running;\n2. Drag the new lares_app.app into Applications and choose replace;\n3. If the first launch says the developer can\'t be verified, right-click the icon and choose Open.';

  @override
  String get updateNextStepsTitle => 'What to do next';

  @override
  String get updateNoReleaseNotes => '(No release notes for this version)';

  @override
  String get updateNoticeIos =>
      'iOS can\'t update from inside the app. If you installed through TestFlight, update there; if you sideloaded with a free signature, the signature expires after 7 days and you need a computer to sideload the new .ipa again.';

  @override
  String get updateNoticeMacos =>
      'On macOS you drag the new version into Applications yourself. Finder opens automatically once the download finishes.';

  @override
  String get updateNoticeNoAssetForPlatform =>
      'This version has no downloadable package for your platform. You can get it manually from the GitHub Releases page.';

  @override
  String get updateNoticeWeb =>
      'The web version updates with the server: a hard refresh (Ctrl/Cmd + Shift + R) is enough.';

  @override
  String get updateQuitting => 'Quitting to finish the update…';

  @override
  String get updateRevealFolder => 'Show in folder';

  @override
  String updateStatusAvailable(String version) {
    return 'New version available: v$version';
  }

  @override
  String get updateStatusCheckFailed => 'The check didn\'t go through.';

  @override
  String get updateStatusChecking => 'Checking…';

  @override
  String get updateStatusDownloading => 'Downloading the update…';

  @override
  String get updateStatusIdle => 'No update check yet.';

  @override
  String get updateStatusReady => 'Download finished, ready to install.';

  @override
  String get updateStatusUpToDate => 'You\'re on the latest version.';

  @override
  String get updateTitle => 'Version and updates';

  @override
  String get updateVersionUnknown => 'Current version unknown';

  @override
  String get updateWinRestarting =>
      'Quitting to finish the update, Lares comes back in a few seconds.';

  @override
  String get widgetNoCircle => 'No circle yet';

  @override
  String get widgetNoCircleHint => 'Open the app and make one';

  @override
  String get widgetNobodyHere => 'Nobody here. Go in and wait a bit?';

  @override
  String widgetPeopleHere(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count people here',
      one: '1 person here',
    );
    return '$_temp0';
  }

  @override
  String widgetPeopleHereWithNames(int count, String names) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count people here · $names',
      one: '1 person here · $names',
    );
    return '$_temp0';
  }

  @override
  String get settingsJoinWithMicOn => 'Mic on when joining';

  @override
  String get settingsJoinWithMicOnSub =>
      'Only when you join yourself. Reconnects never turn your mic on';

  @override
  String get settingsPushNotify => 'Notify me when someone joins';

  @override
  String get settingsPushNotifySub =>
      'Tap Join in the notification to go straight in. Each circle can be turned off separately';

  @override
  String get homeCirclePushOn => 'Notifications for this circle: on';

  @override
  String get homeCirclePushOff => 'Notifications for this circle: off';

  @override
  String get pushPermissionExplain =>
      'Get a notification when a friend joins a circle, and join with one tap.';

  @override
  String get pushPermissionNotNow => 'Not now';

  @override
  String get pushPermissionTurnOn => 'Turn on';

  @override
  String get roomMicPermissionDenied =>
      'Mic is still off: no permission. Allow microphone access in system settings';

  @override
  String get roomMicUnmuteFailed => 'Mic didn\'t turn on. Try again';

  @override
  String get roomMicMuteFailed => 'Couldn\'t mute. Your mic is still on';

  @override
  String get homeAddCircleNameLabel => 'Name';

  @override
  String get homeAddCirclePasscodeLabel => 'Passcode';

  @override
  String get homeAddCirclePasscodeHelper =>
      'We picked one for you. Change it if you like. At least 8 characters';

  @override
  String get homeAddCirclePasscodeTooShort =>
      'Passcode needs at least 8 characters';

  @override
  String get homeAddCircleShuffle => 'Pick another';

  @override
  String get homeCircleCreatedShare =>
      'Your circle is ready. Send the link to whoever should join';

  @override
  String get homeOwnerKeyNote => 'The owner key lives only on this device';

  @override
  String get homeOwnerKeyNoteDesc =>
      'If you switch phones or delete the app, you can\'t manage this circle anymore';

  @override
  String get homeOwnerPending =>
      'Still registering this circle with the server';

  @override
  String get homeChangePasscode => 'Change passcode';

  @override
  String get homeChangePasscodeDesc =>
      'The old passcode stops working now, and everyone but you is let out';

  @override
  String get homeChangePasscodeConfirmTitle => 'Switch to this new passcode?';

  @override
  String homeChangePasscodeConfirmBody(String passcode) {
    return 'New passcode: $passcode\n\nThe old passcode stops working right away. Everyone except you is let out, and only people with the new link can get back in.';
  }

  @override
  String get homeChangePasscodeConfirmYes => 'Switch';

  @override
  String get homeChangePasscodeDone =>
      'Done. Send the new link to everyone who should stay';

  @override
  String get homeDissolveCircle => 'Dissolve circle';

  @override
  String get homeDissolveCircleDesc =>
      'Everyone is let out, and this circle is gone for good';

  @override
  String homeDissolveConfirmTitle(String name) {
    return 'Dissolve \"$name\"?';
  }

  @override
  String get homeDissolveConfirmBody =>
      'This can\'t be undone: everyone is let out right away, nobody can get back in, and this circle can\'t be recreated.\n\nIf you\'re sure, type the circle\'s name below.';

  @override
  String get homeDissolveConfirmYes => 'Dissolve';

  @override
  String get homeCircleDissolved => 'The owner dissolved this circle';

  @override
  String get homeOwnerErrNotOwner =>
      'The owner key on this device doesn\'t match. Nothing changed';

  @override
  String get homeOwnerErrTimeout =>
      'The server didn\'t answer. Try again later';

  @override
  String get homeOwnerErrGeneric => 'That didn\'t work. Try again later';

  @override
  String get e2eeOwnerSwitchDesc =>
      'Turns it on or off for the whole circle. Everyone follows automatically when they join, so nobody ends up unable to hear.';

  @override
  String get e2eeManagedOn => 'The owner turned on end-to-end encryption';

  @override
  String get captionsToggle => 'Captions';

  @override
  String get captionsToggleOn => 'Turn off captions';

  @override
  String get captionsToggleOff =>
      'Turn on captions: show what others say as text';

  @override
  String captionsBanner(String names) {
    return 'Making captions for $names · speech is transcribed by Alibaba Cloud';
  }

  @override
  String get captionsBannerStop => 'Tap to stop';

  @override
  String get captionsStoppedSnack =>
      'Stopped making captions for others. They\'ll be back next time you join';

  @override
  String get captionsNameSeparator => ', ';

  @override
  String get captionsPanelTitle => 'Captions';

  @override
  String get captionsPanelEmpty =>
      'When someone talks, their words show up here';

  @override
  String captionsProviders(String names) {
    return '$names providing captions';
  }

  @override
  String captionsNotProviding(String names) {
    return '$names: captions off';
  }

  @override
  String get captionsAlone => 'No one else is here yet';

  @override
  String get captionsYou => 'Me';

  @override
  String get captionsBannerSelf =>
      'Turning your words into captions · speech is transcribed by Alibaba Cloud';

  @override
  String get captionsArchiveBanner =>
      'This circle keeps a transcript · speech is transcribed by Alibaba Cloud';

  @override
  String get captionsArchiveSelfOff =>
      'Your words aren\'t being transcribed this time';

  @override
  String get captionsArchiveStoppedSnack =>
      'Stopped transcribing your words. It\'ll resume next time you join';

  @override
  String captionsNotTranscribed(String names) {
    return '$names: not transcribed';
  }

  @override
  String captionsBotName(String name) {
    return '$name (bot)';
  }

  @override
  String get chatBotBadge => 'Bot';

  @override
  String get settingsGroupCaptions => 'Live captions';

  @override
  String get settingsCaptionsProvide =>
      'Make captions for people who need them';

  @override
  String get settingsCaptionsProvideSub =>
      'Only while someone here needs captions (or the owner turned on the transcript) and your mic is on, your speech is sent to Alibaba Cloud to turn it into text. No audio is recorded. Turn this off and your words stay out of the transcript too';

  @override
  String get settingsCaptionsE2eeCloud => 'Also in encrypted circles';

  @override
  String get settingsCaptionsE2eeCloudSub =>
      'In an encrypted circle your voice normally never leaves your phone. With this on, your speech is sent to Alibaba Cloud when someone needs captions; the text still reaches them encrypted';

  @override
  String get transcriptTitle => 'Transcript';

  @override
  String get transcriptEmpty =>
      'Nothing here yet. Once the owner turns this on, what people say is kept here as text';

  @override
  String get transcriptLoadError =>
      'Couldn\'t load the transcript. Try again later';

  @override
  String get transcriptRetry => 'Retry';

  @override
  String get transcriptLoadMore => 'Earlier lines';

  @override
  String get transcriptClear => 'Clear transcript';

  @override
  String get transcriptClearConfirmTitle => 'Clear this circle\'s transcript?';

  @override
  String get transcriptClearConfirmBody =>
      'Every line stored on the server will be deleted for everyone. This can\'t be undone';

  @override
  String get transcriptClearConfirmBodyE2ee =>
      'The transcript will be deleted from every member\'s device, and undelivered encrypted lines will be dropped. This can\'t be undone';

  @override
  String get transcriptClearConfirm => 'Clear';

  @override
  String get transcriptCleared => 'Cleared';

  @override
  String get transcriptClearFailed => 'Couldn\'t clear it. Try again later';

  @override
  String get transcriptLocalOnlyNote =>
      'Encrypted circle: the transcript lives only on this device. The server only passes along ciphertext it can\'t read';

  @override
  String get transcriptEntryDesc => 'See what people have said';

  @override
  String get transcriptEntryDescE2ee => 'Stored only on this device';

  @override
  String get transcriptOwnerSwitchDesc =>
      'Turns what people say into text and keeps it on the server until you clear it or delete the circle. Speech is recognized by Alibaba Cloud. Anyone who doesn\'t want to be recorded can turn off captions for others in Settings';

  @override
  String get transcriptOwnerSwitchDescE2ee =>
      'Turns what people say into text, stored encrypted on each member\'s device. Speech is sent to Alibaba Cloud for recognition';

  @override
  String get transcriptE2eeWarnTitle =>
      'Turn on the transcript in an encrypted circle?';

  @override
  String get transcriptE2eeWarnBody =>
      'Once on, everyone\'s speech is sent to Alibaba Cloud to be turned into text, so the audio leaves the phone for that step. The text is then encrypted: the server only passes along ciphertext it can\'t read, and each member keeps the transcript on their own device';

  @override
  String get transcriptE2eeWarnConfirm => 'Turn on';

  @override
  String get botTokensTitle => 'Bots';

  @override
  String get botTokensEntryDesc =>
      'Let outside programs read and post text in this circle';

  @override
  String get botTokensDesc =>
      'A bot holding a token can read the transcript and post messages, captions and short audio, always labeled as a bot. You can revoke it at any time';

  @override
  String get botTokensDescE2ee =>
      'This circle is encrypted. The server can\'t read its content, so bots can\'t read or post here';

  @override
  String get botTokensEmpty => 'No bots yet';

  @override
  String get botTokenCreate => 'New';

  @override
  String get botTokenCreateTitle => 'Name the bot';

  @override
  String get botTokenNameHint => 'For example: meeting notes';

  @override
  String get botTokenShownOnce =>
      'This token is shown only once. Copy it now and keep it somewhere safe';

  @override
  String get botTokenRevoke => 'Revoke';

  @override
  String get botTokenRevokeBody =>
      'Any bot using this token loses access right away';

  @override
  String botTokenCreatedTitle(String name) {
    return 'Token for $name';
  }

  @override
  String botTokenRevokeTitle(String name) {
    return 'Revoke $name?';
  }

  @override
  String get pluginTitle => 'Plugins';

  @override
  String get pluginEntryDesc => 'Add small tools to this circle';

  @override
  String get pluginAdd => 'Add plugin';

  @override
  String get pluginEmpty => 'No plugins yet';

  @override
  String get pluginInstall => 'Install';

  @override
  String get pluginUninstall => 'Remove';

  @override
  String get pluginDetails => 'Details';

  @override
  String get pluginSettings => 'Settings';

  @override
  String pluginUninstallTitle(String name) {
    return 'Remove $name?';
  }

  @override
  String get pluginUninstallBody => 'Its settings and shared state go with it';

  @override
  String pluginInstalled(String name) {
    return '$name is installed';
  }

  @override
  String get pluginAlreadyInstalled => 'Already installed';

  @override
  String get pluginFocusName => 'Focus study';

  @override
  String get pluginFocusDesc =>
      'Focus together, with a pomodoro timer and a leaderboard';

  @override
  String get pluginAddFromUrl => 'Install from URL';

  @override
  String get pluginAddPaste => 'Paste a manifest';

  @override
  String get pluginManifestUrlHint => 'https://…/manifest.json';

  @override
  String get pluginManifestJsonHint =>
      'Paste the contents of manifest.json here';

  @override
  String pluginMeta(String version, String author) {
    return '$version · $author';
  }

  @override
  String get pluginHasWebhook => 'Has a server callback (webhook)';

  @override
  String get pluginSecretsOnce =>
      'This is shown only once. Copy it somewhere safe before closing.';

  @override
  String get pluginToken => 'Plugin token';

  @override
  String get pluginWebhookSecret => 'Webhook secret';

  @override
  String pluginSettingsOf(String name) {
    return '$name settings';
  }

  @override
  String get pluginErrAlreadyInstalled => 'This plugin is already installed';

  @override
  String get pluginErrTooMany => 'A circle can have at most 10 plugins';

  @override
  String get pluginErrBadManifest => 'The manifest is not valid';

  @override
  String get pluginErrFetch => 'Couldn\'t fetch that manifest';

  @override
  String get pluginErrTimeout => 'No reply from the server. Try again later';

  @override
  String get pluginErrNotOwner => 'Only the circle owner can manage plugins';

  @override
  String pluginErrGeneric(String reason) {
    return 'Didn\'t work: $reason';
  }

  @override
  String get pluginErrHttpsOnly => 'The URL needs to start with https://';

  @override
  String get pluginErrBadJson => 'That isn\'t valid JSON';

  @override
  String get pluginConsentTitle => 'Open plugin';

  @override
  String pluginConsentFrom(String origin) {
    return 'From $origin';
  }

  @override
  String get pluginConsentPermsHeader => 'It wants to:';

  @override
  String get pluginConsentNoPerms => 'It doesn\'t need any permissions';

  @override
  String get pluginConsentE2eeWarning =>
      'Heads up: this circle is end-to-end encrypted, but a plugin\'s shared state and callbacks are visible to the server.';

  @override
  String get pluginConsentAllow => 'Allow';

  @override
  String get pluginPlatformUnsupported =>
      'Plugins can\'t be embedded on this platform yet';

  @override
  String get pluginOpenInBrowser => 'Open in browser';

  @override
  String get pluginPermCircleRead => 'See the circle name and settings';

  @override
  String get pluginPermMembersRead =>
      'See who\'s in the room and who comes and goes';

  @override
  String get pluginPermChatRead => 'Read chat messages';

  @override
  String get pluginPermChatSend => 'Send chat messages as you';

  @override
  String get pluginPermCaptionsRead => 'Read live captions';

  @override
  String get pluginPermCaptionsSend => 'Send captions';

  @override
  String get pluginPermTranscriptRead => 'Read the transcript';

  @override
  String get pluginPermStateRead => 'Read the plugin\'s shared state';

  @override
  String get pluginPermStateWrite => 'Change the plugin\'s shared state';

  @override
  String get pluginPermStorage => 'Store data on this device';

  @override
  String get pluginPermFocusRead => 'Read focus status';

  @override
  String get focusTitle => 'Focus study';

  @override
  String get focusPhaseFocus => 'Focusing';

  @override
  String get focusPhaseBreak => 'Break time';

  @override
  String get focusPhaseIdle => 'Not started';

  @override
  String get focusPhaseIdleHint => 'Working quietly together · timer optional';

  @override
  String focusRound(int round, int rounds) {
    return 'Round $round/$rounds';
  }

  @override
  String get focusStart => 'Start focusing';

  @override
  String get focusStop => 'End';

  @override
  String get focusBoard => 'Leaderboard';

  @override
  String get focusLock => 'Lock focus';

  @override
  String get focusLocked => 'Locked';

  @override
  String get focusUnlock => 'Unlock';

  @override
  String get focusLockTitle => 'Lock focus?';

  @override
  String get focusLockBody =>
      'This pins Lares to the screen so other apps and notifications are out of reach. To exit, hold Back and Overview together (or use the gesture the system shows). It unlocks automatically at break or when focus ends.';

  @override
  String get focusLockConfirm => 'Lock';

  @override
  String get focusLockCancel => 'Not now';

  @override
  String get focusLockFailed =>
      'Couldn\'t lock. This device may not support screen pinning';

  @override
  String get focusBadgeFocus => 'Focusing';

  @override
  String focusBadgeAway(String time) {
    return 'Away $time';
  }

  @override
  String get focusBadgeBreak => 'Break';

  @override
  String focusNoticeAway(String name) {
    return '$name stepped away from focus';
  }

  @override
  String focusNoticeBack(String name) {
    return '$name is back';
  }

  @override
  String focusNoticeBackAfter(String name, String time) {
    return '$name is back · away $time';
  }

  @override
  String focusNoticeLeftEarly(String name) {
    return '$name left focus early';
  }

  @override
  String focusNoticePhaseFocus(int round) {
    return 'Round $round — focus';
  }

  @override
  String get focusNoticePhaseBreak => 'Break time — say hi';

  @override
  String get focusNoticeStarted => 'Timer started';

  @override
  String get focusNoticeStopped => 'Timer finished. Nice work';

  @override
  String get focusNoticeEnded => 'The owner turned focus mode off';

  @override
  String get focusErrorForbidden => 'Only the owner can start or end the timer';

  @override
  String get focusErrorGeneric => 'That didn\'t work. Try again in a moment';

  @override
  String get focusBoardToday => 'Today';

  @override
  String get focusBoardWeek => 'This week';

  @override
  String get focusBoardAll => 'All time';

  @override
  String get focusBoardMe => 'Me';

  @override
  String get focusBoardEmpty => 'No one on the board yet. Start focusing';

  @override
  String focusMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String focusHoursMinutes(int hours, int minutes) {
    return '$hours h $minutes min';
  }

  @override
  String get focusSettingsTitle => 'Focus settings';

  @override
  String get focusSettingsFocusMin => 'Focus length';

  @override
  String get focusSettingsBreakMin => 'Break length';

  @override
  String get focusSettingsRounds => 'Rounds';

  @override
  String focusSettingsRoundsValue(int count) {
    return '$count rounds';
  }

  @override
  String get focusSettingsGrace => 'Grace before \"away\"';

  @override
  String focusSettingsGraceValue(int seconds) {
    return '$seconds s';
  }

  @override
  String get focusSettingsGraceHint =>
      'How long someone can switch apps before counting as away';

  @override
  String get focusSettingsMembersCanStart => 'Members can start the timer';

  @override
  String get focusSettingsSave => 'Save';

  @override
  String get focusSettingsPrivacy =>
      'Focus status (who is focusing, time away, the leaderboard) is visible to the server, even in encrypted circles';

  @override
  String get featureCaptions => 'Live captions';

  @override
  String get featureTranscript => 'Transcript';

  @override
  String get featureVoiceNotes => 'Voice notes';

  @override
  String get featureMap => 'Location map';

  @override
  String get featureRecording => 'Recording';

  @override
  String get featurePlugins => 'Plugins';

  @override
  String get featureFocus => 'Focus study';

  @override
  String get featureP2p => 'Direct peer-to-peer';

  @override
  String get featureDevTools => 'Developer readouts';

  @override
  String get roomMore => 'More';

  @override
  String get roomMoreOn => 'On';

  @override
  String get roomMoreOff => 'Off';

  @override
  String get roomMoreVoiceNotesHint => 'Hold to record';

  @override
  String roomMoreVoiceNotesPending(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count to hear · hold to record',
    );
    return '$_temp0';
  }

  @override
  String get roomMoreVoiceNotesRecording => 'Release to send';

  @override
  String get roomTranscriptNotice => 'This circle keeps a transcript';

  @override
  String get roomTranscriptNoticeOpen => 'View transcript';

  @override
  String get ownerFeaturesTitle => 'Features';

  @override
  String get ownerFeaturesEntryDesc =>
      'What this circle has on, and what it is for';

  @override
  String get ownerFeaturesHint =>
      'Voice and text chat are always on. Turn the rest on as needed — only for this circle.';

  @override
  String get ownerFeatureCaptionsDesc =>
      'Live speech-to-text; audio is sent to a cloud recognizer';

  @override
  String get ownerFeatureTranscriptDesc =>
      'Keeps a text record members can look back on';

  @override
  String get ownerFeatureVoiceNotesDesc =>
      'Leave a short voice message for the circle';

  @override
  String get ownerFeatureMapDesc =>
      'Those who want to can share their location on a map';

  @override
  String get ownerFeatureRecordingDesc =>
      'Record the room, with everyone\'s consent';

  @override
  String get ownerFeatureRecordingUnavailable =>
      'Recording isn\'t in this build yet — this sets it for later';

  @override
  String get ownerFeaturePluginsDesc => 'Allow third-party plugins';

  @override
  String get ownerFeatureFocusDesc => 'Pomodoro timer and shared focus board';

  @override
  String get ownerFeatureP2pDesc =>
      'Connect directly when few are in, for lower latency';

  @override
  String get ownerFeatureDevToolsDesc =>
      'Show join timing and other debug readouts';

  @override
  String ownerFeatureToggleFailed(String feature, String reason) {
    return 'Couldn\'t change \"$feature\": $reason';
  }

  @override
  String get purposeTitle => 'Purpose';

  @override
  String get purposeNone => 'Not set';

  @override
  String get purposePickerTitle => 'What is this circle for?';

  @override
  String get purposeChat => 'Hang out';

  @override
  String get purposeChatDesc =>
      'Just talk. Voice notes on; captions and transcript off';

  @override
  String get purposeStudy => 'Study';

  @override
  String get purposeStudyDesc =>
      'Focus together with a pomodoro timer, fewer distractions';

  @override
  String get purposeMeeting => 'Meeting';

  @override
  String get purposeMeetingDesc =>
      'Live captions and a transcript to look back on';

  @override
  String get purposeCustom => 'Custom';

  @override
  String get purposeCustomDesc =>
      'Pick features and plugins yourself, or use a share code';

  @override
  String get purposeCreateLabel => 'Purpose';

  @override
  String get purposeCreateHint =>
      'Applied once the circle is registered; you can change it any time';

  @override
  String purposeApplied(String name) {
    return 'Switched to \"$name\"';
  }

  @override
  String purposeApplyFailed(String reason) {
    return 'Couldn\'t change the purpose: $reason';
  }

  @override
  String purposeReasonBad(String detail) {
    return 'something in it is off ($detail)';
  }

  @override
  String purposeReasonManifest(String detail) {
    return 'a plugin manifest is off ($detail)';
  }

  @override
  String get purposeReasonFetch => 'a plugin address couldn\'t be reached';

  @override
  String get purposeReasonTooMany => 'more than 10 plugins';

  @override
  String get purposeReasonFeatureOff => 'plugins are off in this circle';

  @override
  String get purposeReasonUnknownBuiltin =>
      'the server doesn\'t know that built-in plugin';

  @override
  String get purposeReasonNotRegistered =>
      'the circle is still being registered; try again shortly';

  @override
  String get purposeExport => 'Export share code';

  @override
  String get purposeImport => 'Import share code';

  @override
  String get purposeExportFailed => 'Couldn\'t export; try again shortly';

  @override
  String get purposeCodeTitle => 'Share code';

  @override
  String get purposeCodeHint =>
      'Paste this into \"Import share code\" to use the same setup. It has no passcode or plugin secrets.';

  @override
  String get purposeCodeCopied => 'Share code copied';

  @override
  String get purposeCodeErrPrefix =>
      'That doesn\'t look like a share code — it starts with lares-purpose:';

  @override
  String get purposeCodeErrBroken =>
      'The code looks cut off; it may not have copied fully';

  @override
  String get purposeCodeErrTooLarge => 'That code is too large';

  @override
  String get purposeCodeErrJson => 'Couldn\'t read what\'s inside that code';

  @override
  String get purposeImportTitle => 'Import share code';

  @override
  String get purposeImportFieldHint => 'Paste lares-purpose:… here';

  @override
  String get purposeImportApply => 'Apply';

  @override
  String get purposeImportFill => 'Fill in';

  @override
  String get purposePreviewNoChange => 'No feature changes';

  @override
  String purposePreviewTurnsOn(String list) {
    return 'Turns on: $list';
  }

  @override
  String purposePreviewTurnsOff(String list) {
    return 'Turns off: $list';
  }

  @override
  String purposePreviewPlugins(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Touches $count plugins',
      one: 'Touches 1 plugin',
    );
    return '$_temp0';
  }

  @override
  String purposePreviewSettings(String list) {
    return 'Circle settings: $list';
  }

  @override
  String get purposeEditorTitle => 'Custom purpose';

  @override
  String get purposeEditorFormat => 'Format';

  @override
  String get purposeEditorImport => 'Import from share code';

  @override
  String get purposeEditorCopyCode => 'Copy share code';

  @override
  String get purposeEditorFormatFailed => 'Fix the syntax error first';

  @override
  String get purposeEditorValid => 'Looks good';

  @override
  String get purposeEditorChecking => 'Checking…';

  @override
  String purposeEditorLine(int line) {
    return 'line $line';
  }

  @override
  String get purposeEditorApply => 'Apply';

  @override
  String purposeErrSyntax(int line, int column) {
    return 'JSON syntax error (line $line, column $column)';
  }

  @override
  String get purposeErrNotObject => 'The top level must be a JSON object';

  @override
  String get purposeErrTooLarge => 'Too large — 32 KB at most';

  @override
  String get purposeErrUnknownKey => 'Unknown key';

  @override
  String get purposeErrVersion => 'v must be 1';

  @override
  String get purposeErrId => 'id: lowercase letters, digits, - and _, up to 32';

  @override
  String get purposeErrName => 'Name is required, up to 24 characters';

  @override
  String get purposeErrIcon => 'Icon should be a single emoji';

  @override
  String get purposeErrDescription => 'Description is 200 characters at most';

  @override
  String get purposeErrNotBool => 'Must be true or false';

  @override
  String get purposeErrNotObjectField => 'This must be a JSON object';

  @override
  String get purposeErrNotArray => 'This must be a JSON list';

  @override
  String get purposeErrTooManyPlugins => '10 plugins at most';

  @override
  String get purposeErrPluginSource =>
      'Use exactly one of id, manifest, manifestUrl';

  @override
  String get purposeErrPluginId => 'Invalid plugin id';

  @override
  String get purposeErrConfigTooLarge => 'Plugin config is 4 KB at most';

  @override
  String get purposeErrManifestUrl => 'Must be an https:// address';

  @override
  String purposeErrManifest(String field) {
    return 'Plugin manifest: \"$field\" is invalid';
  }

  @override
  String purposeErrConflict(String field) {
    return 'Conflicts with $field';
  }

  @override
  String get purposeErrDuplicate => 'Same plugin listed twice';

  @override
  String get privacySheetTitle => 'Privacy in this circle';

  @override
  String get privacySheetTranscript =>
      'Transcript on (speech is recognized by Alibaba Cloud; the text and nicknames stay on the server until the owner clears them)';

  @override
  String get privacySheetTranscriptE2ee =>
      'Transcript on (speech is recognized by Alibaba Cloud; the server only relays ciphertext, records live on each member\'s device)';

  @override
  String get privacySheetCaptions =>
      'Live captions available (when someone turns captions on, snippets of your speech go to Alibaba Cloud for recognition; the app keeps none of it)';

  @override
  String privacySheetPlugins(int count, String names) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count plugins',
      one: '1 plugin',
    );
    return '$_temp0 ($names)';
  }

  @override
  String privacySheetPluginDetail(String name, String perms) {
    return '$name: $perms';
  }

  @override
  String get privacySheetPluginNoPerms => 'no permissions';

  @override
  String get privacySheetPluginThirdParty =>
      ' · data is sent to the plugin author\'s server (third party)';

  @override
  String get privacySheetSeparator => ', ';

  @override
  String get privacySheetFocus =>
      'Focus tracking on (the circle can see who\'s focusing and how long they\'ve been away)';

  @override
  String get privacySheetMap =>
      'Location sharing available (only shared when you turn it on yourself)';

  @override
  String get privacySheetRecording =>
      'Recording on (everyone in the room sees a notice while recording)';

  @override
  String get privacySheetNothing =>
      'Nothing here processes your data beyond voice and chat — no transcript, no plugins';

  @override
  String get privacySheetE2eeOn => 'End-to-end encryption: yes';

  @override
  String get privacySheetE2eeOff => 'End-to-end encryption: no';

  @override
  String get privacySheetE2eeUnset =>
      'End-to-end encryption: no circle-wide rule, each member\'s own setting applies';

  @override
  String get privacySheetAi =>
      'AI assistant on (voice in the room is sent to Alibaba Cloud Model Studio DashScope for recognition and replies)';

  @override
  String get aiVoicePluginName => 'AI assistant';

  @override
  String get aiVoicePluginDesc =>
      'A talking assistant in the room — call it and it answers';

  @override
  String get aiVoiceSettingsTitle => 'AI assistant settings';

  @override
  String get aiVoicePrivacyNote =>
      'When on, voice in the room is sent to Alibaba Cloud Model Studio (DashScope) for recognition, and an AI writes and speaks the reply. Replies are AI-generated and can be wrong. Not available in end-to-end encrypted circles.';

  @override
  String get aiVoiceE2eeBlocked =>
      'This circle uses end-to-end encryption, so the server can\'t hear voice and the AI assistant can\'t work';

  @override
  String get aiVoiceFieldName => 'Name (also the wake word)';

  @override
  String get aiVoiceFieldNameEmpty => 'Give it a name';

  @override
  String get aiVoiceFieldWakeWords => 'Other names';

  @override
  String get aiVoiceFieldWakeWordsHint => 'Separate with commas or spaces';

  @override
  String get aiVoiceFieldPersona => 'Persona';

  @override
  String get aiVoicePersonaReset => 'Reset to default';

  @override
  String get aiVoiceFieldTrigger => 'When it answers';

  @override
  String get aiVoiceTriggerWake => 'By name';

  @override
  String get aiVoiceTriggerAlways => 'Always';

  @override
  String get aiVoiceTriggerPtt => '@ only';

  @override
  String get aiVoiceTriggerWakeDesc =>
      'Answers only when someone says its name or another wake word';

  @override
  String get aiVoiceTriggerAlwaysDesc =>
      'Answers whenever someone finishes speaking — good for one person chatting with it';

  @override
  String aiVoiceTriggerPttDesc(String name) {
    return 'Doesn\'t listen to voice; answers only chat messages starting with @$name';
  }

  @override
  String get aiVoiceFieldVoice => 'Voice';

  @override
  String get aiVoiceFieldInterrupt => 'Stop when someone talks over it';

  @override
  String get aiVoiceAdvanced => 'Advanced';

  @override
  String get aiVoiceFieldModel => 'Chat model';

  @override
  String get aiVoiceFieldModelInvalid =>
      'Letters, digits, dots, dashes and underscores only';

  @override
  String get aiVoiceFieldMaxReplyChars => 'Max characters per reply';

  @override
  String get aiVoiceFieldMaxTurnsPerHour => 'Max answers per hour';

  @override
  String get aiVoiceFieldMaxTurnsPerDay => 'Max answers per day';

  @override
  String aiVoiceRangeHint(int min, int max) {
    return '$min–$max';
  }

  @override
  String aiVoiceRangeError(int min, int max) {
    return 'Must be between $min and $max';
  }

  @override
  String get aiVoiceSaved => 'Saved';

  @override
  String aiVoiceSaveFailed(String reason) {
    return 'Couldn\'t save: $reason';
  }

  @override
  String get aiVoiceSeatStatus => 'AI assistant';

  @override
  String get aiVoiceSeatBadge => 'AI';

  @override
  String get aiVoiceModerationHint =>
      'This is the AI assistant. The owner can turn it off under Plugins';

  @override
  String get roomMoreAi => 'AI assistant';

  @override
  String roomMoreAiTitle(String name) {
    return 'AI assistant “$name”';
  }

  @override
  String roomMoreAiHowWake(String name) {
    return 'Say “$name”, then your question';
  }

  @override
  String get roomMoreAiHowAlways => 'Finish speaking and it will answer';

  @override
  String roomMoreAiHowPtt(String name) {
    return 'Type @$name in the chat';
  }

  @override
  String get roomMoreAiPrivacy =>
      'Voice in the room is sent to Alibaba Cloud Model Studio (DashScope) for recognition. Replies are AI-generated and can be wrong.';

  @override
  String get purposeMeetingAiSwitch => 'Add the AI assistant';

  @override
  String get purposeMeetingAiDesc =>
      'Call it by name during the meeting to ask questions; voice is sent to Alibaba Cloud DashScope';

  @override
  String get purposeMeetingAiE2ee =>
      'This circle uses end-to-end encryption, so the AI assistant isn\'t available';

  @override
  String get purposeMeetingAiConfirm => 'Use Meeting';

  @override
  String get privacySheetFullPolicy => 'Full privacy policy';

  @override
  String get pushLevelTitle => 'Notify me';

  @override
  String get pushLevelAll => 'Everything';

  @override
  String get pushLevelAllDesc =>
      'Focus sessions, a lively room, or the owner calling';

  @override
  String get pushLevelCalled => 'Only when called';

  @override
  String get pushLevelCalledDesc => 'Only when the owner calls everyone in';

  @override
  String get pushLevelOff => 'Off';

  @override
  String get pushLevelOffDesc => 'No notifications from this circle';

  @override
  String pushLevelTile(String level) {
    return 'Notify me: $level';
  }

  @override
  String get pushQuietTitle => 'Quiet hours for pushes';

  @override
  String get pushQuietOffSub => 'Off — circle activity can reach you any time';

  @override
  String pushQuietOnSub(String range) {
    return 'No circle activity pushes $range';
  }

  @override
  String get pushQuietSwitch => 'Quiet hours';

  @override
  String get pushQuietHint =>
      'Uses this phone\'s time zone. Owner calls and weekly summaries wait too.';

  @override
  String get pushQuietDone => 'Done';

  @override
  String get pushTriggersTitle => 'Activity alerts';

  @override
  String get pushTriggersSub =>
      'Tell members who aren\'t in the room when something\'s happening';

  @override
  String get pushTriggerFocus => 'Someone starts focusing';

  @override
  String get pushTriggerFocusDesc => '\"Aman started focusing — join in?\"';

  @override
  String get pushTriggerCrowd => 'The room gets lively';

  @override
  String pushTriggerCrowdDesc(int count) {
    return '\"$count people are already talking\" — once per session';
  }

  @override
  String get pushTriggerCrowdN => 'Alert at';

  @override
  String pushTriggerCrowdNValue(int count) {
    return '$count people';
  }

  @override
  String get pushTriggerArrive => 'Someone enters an empty room';

  @override
  String get pushTriggerArriveDesc =>
      '\"Lulu is here\" — off by default, it can get noisy';

  @override
  String get pushTriggersReset => 'Restore purpose defaults';

  @override
  String get pushTriggersPurpose =>
      'Using the defaults for this circle\'s purpose';

  @override
  String pushTriggersLimits(int cooldown, int cap) {
    return 'Each person gets at most one alert per circle every $cooldown min and $cap a day; anyone in the room or who just left isn\'t notified.';
  }

  @override
  String get pushTriggersLoading => 'Loading…';

  @override
  String get pushTriggersFailed => 'Couldn\'t save — try again later';

  @override
  String get summonButton => 'Call everyone';

  @override
  String summonCooldown(int minutes) {
    return 'You can call again in $minutes min';
  }

  @override
  String summonCooldownShort(int minutes) {
    return '${minutes}m';
  }

  @override
  String summonSent(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Called $count people',
      one: 'Called 1 person',
    );
    return '$_temp0';
  }

  @override
  String get summonNobody =>
      'Nobody to call right now (notifications off or quiet hours)';

  @override
  String get summonFailed => 'Couldn\'t call everyone — try again later';

  @override
  String get summonConfirmTitle => 'Call everyone in?';

  @override
  String summonConfirmBody(String name, int minutes) {
    return 'Members who aren\'t here get \"$name is calling you to the circle\". Once every $minutes min.';
  }

  @override
  String focusRoundAllIn(int count) {
    return 'All $count stayed the whole round 🎉';
  }

  @override
  String get focusRoundSolo => 'Full round 🎉';

  @override
  String focusRoundPartial(int full, int total) {
    return '$full/$total stayed the whole round';
  }

  @override
  String focusRoundAway(String name, int minutes) {
    return '$name away $minutes min';
  }

  @override
  String focusRoundAwayBrief(String name) {
    return '$name stepped away';
  }

  @override
  String focusRoundMore(int count) {
    return '+$count more';
  }

  @override
  String focusRoundTitle(int round) {
    return 'Round $round done';
  }

  @override
  String get focusRoundDismiss => 'Dismiss';

  @override
  String focusStreakTooltip(int days) {
    return '$days-day focus streak';
  }

  @override
  String get focusWeeklyTitle => 'Last week\'s focus';

  @override
  String focusWeeklyTime(String time) {
    return 'You focused for $time';
  }

  @override
  String focusWeeklyRank(int rank, int of) {
    return '#$rank of $of in the circle';
  }

  @override
  String focusWeeklyStreak(int days) {
    return '$days-day streak 🔥';
  }

  @override
  String focusWeeklyTotal(String time) {
    return 'Circle total $time';
  }

  @override
  String get focusWeeklyDismiss => 'Got it';
}
