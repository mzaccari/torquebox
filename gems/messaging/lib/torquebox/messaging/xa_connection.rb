# Copyright 2008-2011 Red Hat, Inc, and individual contributors.
# 
# This is free software; you can redistribute it and/or modify it
# under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation; either version 2.1 of
# the License, or (at your option) any later version.
# 
# This software is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# Lesser General Public License for more details.
# 
# You should have received a copy of the GNU Lesser General Public
# License along with this software; if not, write to the Free
# Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA
# 02110-1301 USA, or see the FSF site: http://www.fsf.org.

module TorqueBox
  module Messaging

    attr_accessor :jms_connection
    
    class XaConnection
      def initialize(jms_connection)
        @jms_connection = jms_connection
      end

      def start
        @jms_connection.start
      end

      def close
        @jms_connection.close
      end

      def client_id
        @jms_connection.client_id
      end

      def client_id=(client_id)
        @jms_connection.client_id = client_id
      end
      
      def with_new_session(transacted=false, ack_mode=Session::AUTO_ACK, &block)
        session = self.create_session( transacted, ack_mode )
        begin
          result = block.call( session )
        ensure
          session.close
        end
        return result
      end

      def create_session()
        XaSession.new( @jms_connection.create_xa_session(), self )
      end

    end
  end
end