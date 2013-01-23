smake
=====

smart make tool for erlang


test example:

environment : machine A and machine B is in a LAN, machine A is the master compile server, it keeps alive 24 hours.
Now, a user tries to compile his erl code in machine B .

machine A: erl -name compile_server@IPA -setcookie abc

machine B: erl -name user@IPB -setcookie abc -eval "smake:all([{compile_server, 'compile_server@IPA'}])"

IPA is the ip of machine A, IPB is the ip of machine B.

What happens  when you use smake:all/1,2 ???

First, it will join the cluster in which many computers in the LAN connect with each other.

Second, it will create remote_worker and local_worker ready to compile the source file.

Third , the master process in your computer will deliver compiling task to the remote_worker and the local_worker.

What changes in compile2.erl , epp2.erl, file2.erl ???

I change them to read and write the remote file.

In file2.erl, I use gen_server:call({?FILE_SERVER, node(group_leader())}, Request), 
    replace         gen_server:call({?FILE_SERVER, Request).

The implemention is very simple, and notice that I just test it in OTP_R15B, in higher otp release version ,you should
make a test.

呵呵，公司局域网里面空闲的机子还是很多的，欢迎提bug。

Email:      shoumuyushan@gmail.com
Tecent QQ:    812445367
