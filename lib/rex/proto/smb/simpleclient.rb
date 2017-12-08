# -*- coding: binary -*-
module Rex
module Proto
module SMB
class SimpleClient

require 'rex/text'
require 'rex/struct2'
require 'rex/proto/smb/constants'
require 'rex/proto/smb/exceptions'
require 'rex/proto/smb/evasions'
require 'rex/proto/smb/crypt'
require 'rex/proto/smb/utils'
require 'rex/proto/smb/client'
require 'rex/proto/smb/simpleclient/open_file'
require 'rex/proto/smb/simpleclient/open_pipe'
require 'ruby_smb'

# Some short-hand class aliases
CONST = Rex::Proto::SMB::Constants
CRYPT = Rex::Proto::SMB::Crypt
UTILS = Rex::Proto::SMB::Utils
XCEPT = Rex::Proto::SMB::Exceptions
EVADE = Rex::Proto::SMB::Evasions

# Public accessors
attr_accessor :last_error, :server_max_buffer_size

# Private accessors
attr_accessor :socket, :client, :direct, :shares, :last_share

  # Pass the socket object and a boolean indicating whether the socket is netbios or cifs
  def initialize(socket, direct = false)
    self.socket = socket
    self.direct = direct

    self.client = RubySMB::Client.new(RubySMB::Dispatcher::Socket.new(self.socket, read_timeout: 60),
                                      username: '',
                                      password: '')#Rex::Proto::SMB::Client.new(socket)
    self.client.class.module_eval { attr_accessor :evasion_opts}
    self.client.evasion_opts = {}

    self.shares = { }
    self.server_max_buffer_size = 1024 # 4356 (workstation) or 16644 (server) expected
  end

  def login(name = '', user = '', pass = '', domain = '',
      verify_signature = false, usentlmv2 = false, usentlm2_session = true,
      send_lm = true, use_lanman_key = false, send_ntlm = true,
      native_os = 'Windows 2000 2195', native_lm = 'Windows 2000 5.0', spnopt = {})

    begin

      if (self.direct != true)
        self.client.session_request(name)
      end
      self.client.native_os = native_os
      self.client.native_lm = native_lm
      self.client.verify_signature = verify_signature
      self.client.use_ntlmv2 = usentlmv2
      self.client.usentlm2_session = usentlm2_session
      self.client.send_lm = send_lm
      self.client.use_lanman_key =  use_lanman_key
      self.client.send_ntlm = send_ntlm

      ok = self.client.negotiate
      self.server_max_buffer_size = ok['Payload'].v['MaxBuff']

      # Disable NTLMv2 Session for Windows 2000 (breaks authentication on some systems)
      # XXX: This in turn breaks SMB auth for Windows 2000 configured to enforce NTLMv2
      # XXX: Tracked by ticket #4785#4785
      if self.client.native_lm =~ /Windows 2000 5\.0/ and usentlm2_session
      #	self.client.usentlm2_session = false
      end

      self.client.spnopt = spnopt

      # In case the user unsets the password option, we make sure this is
      # always a string
      pass ||= ''

      ok = self.client.session_setup(user, pass, domain)
    rescue ::Interrupt
      raise $!
    rescue ::Exception => e
      n = XCEPT::LoginError.new
      n.source = e
      if(e.respond_to?('error_code'))
        n.error_code   = e.error_code
        n.error_reason = e.get_error(e.error_code)
      end
      raise n
    end

    return true
  end


  def login_split_start_ntlm1(name = '')

    begin

      if (self.direct != true)
        self.client.session_request(name)
      end

      # Disable extended security
      self.client.negotiate(false)
    rescue ::Interrupt
      raise $!
    rescue ::Exception => e
      n = XCEPT::LoginError.new
      n.source = e
      if(e.respond_to?('error_code'))
        n.error_code   = e.error_code
        n.error_reason = e.get_error(e.error_code)
      end
      raise n
    end

    return true
  end


  def login_split_next_ntlm1(user, domain, hash_lm, hash_nt)
    begin
      ok = self.client.session_setup_no_ntlmssp_prehash(user, domain, hash_lm, hash_nt)
    rescue ::Interrupt
      raise $!
    rescue ::Exception => e
      n = XCEPT::LoginError.new
      n.source = e
      if(e.respond_to?('error_code'))
        n.error_code   = e.error_code
        n.error_reason = e.get_error(e.error_code)
      end
      raise n
    end

    return true
  end

  def connect(share)
    ok = self.client.tree_connect(share)

    if ok.respond_to?(:id)
      tree_id = ok.id
    else
      tree_id = ok['Payload']['SMB'].v['TreeID']
    end

    self.shares[share] = tree_id
    self.last_share = share
  end

  def disconnect(share)
    if self.shares[share]
      ok = self.client.tree_disconnect(self.shares[share])
      self.shares.delete(share)
      return ok
    end
    false
  end


  def open(path, perm, chunk_size = 48000)
    mode   = UTILS.open_mode_to_mode(perm)
    access = UTILS.open_mode_to_access(perm)

    ok = self.client.open(path, mode, access)
    file_id = ok['Payload'].v['FileID']
    fh = OpenFile.new(self.client, path, self.client.last_tree_id, file_id)
    fh.chunk_size = chunk_size
    fh
  end

  def delete(*args)
    self.client.delete(*args)
  end

  def create_pipe(path, perm = 'c')
    disposition = UTILS.create_mode_to_disposition(perm)
    ok = self.client.create_pipe(path, disposition)
    if ok.respond_to? :guid
      file_id = ok.guid
    elsif ok.respond_to? :fid
      file_id = ok.fid
    else
      file_id = ok['Payload'].v['FileID']
    end
    fh = OpenPipe.new(self.client, path, self.client.last_tree_id, file_id)
  end

  def trans_pipe(fid, data, no_response = nil)
    client.trans_named_pipe(fid, data, no_response)
  end

end
end
end
end

