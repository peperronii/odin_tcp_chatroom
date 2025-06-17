package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "core:sys/posix"

Client_Data :: struct {
	name:     [64]u8,
	socket:   net.TCP_Socket,
	endpoint: net.Endpoint,
}

global_context: runtime.Context
client_list_mutex: sync.Mutex
client_list: map[posix.pthread_t]Client_Data
broadcast_queue_mutex: sync.Mutex
broadcast_queue: [dynamic][576]u8

main :: proc() {
	default_allocator := context.allocator
	tracking_allocator: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking_allocator, default_allocator)
	context.allocator = mem.tracking_allocator(&tracking_allocator)
	reset_tracking_allocator :: proc(a: ^mem.Tracking_Allocator) -> bool {
		err := false

		for _, val in a.allocation_map {
			fmt.printf("%v leaked: %v bytes \n", val.location, val.size)
			err := true
		}

		for val in a.bad_free_array {
			fmt.printf("%v Bad Free: %v bytes", val.location, val.memory)
		}
		mem.tracking_allocator_clear(a)
		return err
	}
	defer reset_tracking_allocator(&tracking_allocator)

	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)

	global_context = context

	err := run_server()
	if err != nil {
		fmt.eprintln("Exit with Error : ", err)
	}
	fmt.println("Server Closed Successfully")
}

run_server :: proc() -> net.Network_Error {

	defer for t, c in client_list {
		posix.pthread_join(t)
		net.close(c.socket)
	}

	broadcast_socket := net.make_unbound_udp_socket(.IP4) or_return
	udp_thread : posix.pthread_t
	posix.pthread_create(&udp_thread, nil, broadcast_udp, &broadcast_socket)

	server_socket := net.listen_tcp(
		net.Endpoint{address = net.IP4_Loopback, port = 4343},
	) or_return
	defer net.close(server_socket)

	
	for {
		fmt.println("Accepting...")
		client_socket, client_endpoint, client_err := net.accept_tcp(server_socket)
		if client_err != nil {
			log.error("Error Accepting Client: ", client_err)
			log.info("Continue Listening...")
			continue
		}
		log.info("Hello New Client!")
		if sync.guard(&client_list_mutex) {
			tid: posix.pthread_t
			thread_err := posix.pthread_create(&tid, nil, handle_client, nil)
			if thread_err != nil {
				log.error("Thread Creation Error: ", thread_err)
				log.info("Closing Client Socket")
				net.close(client_socket)
				log.info("Continue Listening...")
			} else {
				log.info("Thread Created Successfully!")
				client_list[tid] = {{}, client_socket, client_endpoint}
			}
		}

	}
	return nil
}

handle_client :: proc "c" (arg: rawptr) -> rawptr {

	context = global_context

	name_buf: [64]u8
	message_buf: [512]u8
	client_socket: net.TCP_Socket
	client_endpoint: net.Endpoint

	log.info("Trying peer_endpoint")
	buf_endpoint, err := net.peer_endpoint(client_socket)
	if err != nil {
		log.error("Error getting peer endpoint", err)
	}
	log.info(buf_endpoint)
	if sync.guard(&client_list_mutex) {
		buf := client_list[posix.pthread_self()]
		client_endpoint = buf.endpoint
		client_socket = buf.socket
	}

	defer if sync.guard(&client_list_mutex) {
		log.info("Deleting from list")
		delete_key(&client_list, posix.pthread_self())
		log.info("Closing Sucessful")
	}

	defer {
		log.info("Closing Socket", client_socket)
		net.close(client_socket)
	}

	defer log.info("Closing Thread : ", posix.pthread_self())
	for {
		//recieve name until valid
		_, err := net.recv(client_socket, name_buf[:])
		if err != nil {
			log.error("Error Recieving Name: ", err)
			return nil
		}

		log.infof("Got Name: %s", name_buf)
		if sync.guard(&client_list_mutex) {
			duplicate := false
			for _, v in client_list {
				if name_buf == v.name {
					duplicate = true
					break
				}
			}

			if !duplicate {
				client_list[posix.pthread_self()] = {name_buf, client_socket, client_endpoint}
				message_buf[0] = '1' //Name Valid , Login Success
				log.info("Name Accepted from :", client_endpoint)
				_, err := net.send(client_socket, message_buf[0:1])
				if err != nil {
					log.error("Error Sending Name Accept: ", err)
					return nil
				}
				break
			}

			message_buf[0] = '0' //Name Invalid, Duplicate or Empty
			log.info("Name Declined to :", client_endpoint)
			_, err := net.send(client_socket, message_buf[0:1])
			if err != nil {
				log.error("Error Sending Name Decline: ", err)
				return nil
			}
		}
	}

	for {
		peer_endpoint: {
			log.info("Trying peer_endpoint")
			buf_endpoint, err := net.peer_endpoint(client_socket)
			if err != nil {
				log.error("Error getting peer endpoint", err)
			}
			log.info(buf_endpoint)
		}
		message_buf = {} //clear buffer

		b, err := net.recv_tcp(client_socket, message_buf[:])
		if b == 0 {
			log.info("No more message, terminating thread")
			return nil
		}
		if err != nil {
			log.error("Error Recieving Message")
			return nil
		}

		log.infof("Got message from %s at %v: %s" , name_buf,client_endpoint, message_buf)
		broadcast_buf : [576]u8
		for i in 0..<64{
			broadcast_buf[i] = name_buf[i]
		}

		for i in 64..<576{
			broadcast_buf[i] = message_buf[i-64]
		}

		log.infof("%s",broadcast_buf)
		if sync.guard(&broadcast_queue_mutex) {
			append(&broadcast_queue, broadcast_buf)
		}
		
	}
	return nil
}

broadcast_udp :: proc "c" (broadcast_socket: rawptr) -> rawptr {
	context = global_context
	broadcast_socket := (cast(^net.UDP_Socket)(broadcast_socket))^
	for {
		if len(broadcast_queue) > 0 {
			broadcast_message : [576]u8
			if sync.guard(&broadcast_queue_mutex) {
				broadcast_message = pop_front(&broadcast_queue)
			}
			if sync.guard(&client_list_mutex) {
				for _, c in client_list {
					net.send(broadcast_socket, broadcast_message[:], c.endpoint)
				}
			}
		}
	}
	return nil
}
